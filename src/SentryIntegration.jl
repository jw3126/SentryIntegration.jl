module SentryIntegration

using Logging: Info, Warn, Error, LogLevel
using UUIDs
using Dates
using HTTP
using JSON
using PkgVersion
using CodecZlib

const VERSION = @PkgVersion.Version 0

export capture_message,
    capture_exception,
    start_transaction,
    finish_transaction,
    set_task_transaction,
    set_tag,
    Info,
    Warn,
    Error


include("structs.jl")
include("transactions.jl")

##############################
# * Init
#----------------------------


const main_hub = Hub()
const global_tags = Dict{String,String}()

function init(dsn=nothing ; traces_sample_rate=nothing, traces_sampler=nothing, debug=false, release=nothing)
    main_hub.initialised && @warn "Sentry already initialised."
    if dsn === nothing
        dsn = get(ENV, "SENTRY_DSN", nothing)
        if dsn === nothing
            # Abort - pretend nothing happened
            @warn "No DSN for SentryIntegration"
            return
        end
    end

    if !main_hub.initialised
        atexit(clear_queue)
    end

    main_hub.debug = debug
    main_hub.dsn = dsn

    upstream, project_id, public_key = parse_dsn(dsn)
    main_hub.upstream = upstream
    main_hub.project_id = project_id
    main_hub.public_key = public_key

    main_hub.release = release

    @assert traces_sample_rate === nothing || traces_sampler === nothing
    if traces_sample_rate !== nothing
        main_hub.traces_sampler = RatioSampler(traces_sample_rate)
    elseif traces_sampler !== nothing
        main_hub.traces_sampler = traces_sampler
    else
        main_hub.traces_sampler = NoSamples()
    end

    main_hub.sender_task = @async send_worker()
    bind(main_hub.queued_tasks, main_hub.sender_task)
    main_hub.initialised = true

    nothing
end

function parse_dsn(dsn)
    dsn == "fake" && return (; upstream="", project_id="", public_key="")

    m = match(r"(?'protocol'\w+)://(?'public_key'\w+)@(?'hostname'[\w\.]+(?::\d+)?)/(?'project_id'\w+)"a, dsn)
    m === nothing && error("dsn does not fit correct format")

    upstream = "$(m[:protocol])://$(m[:hostname])"

    return (; upstream, project_id=m[:project_id], public_key=m[:public_key])
end

####################################################
# * Globally applied things
#--------------------------------------------------


function set_tag(tag::String, data::String)
    if tag == "release"
        @warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call"
    end
    global_tags[tag] = data
end

##############################
# * Utils
#----------------------------

# Need to have an extra Z at the end - this indicates UTC
nowstr() = string(now(UTC)) * "Z"

# Useful util
macro ignore_exception(ex)
    quote
        try
            $(esc(ex))
        catch exc
            @error "Ignoring problem in sentry" exc
        end
    end
end


################################
# * Communication
#------------------------------

function generate_uuid4()
    # This is mostly just printing the UUID4 in the format we want.
    val = uuid4().value
    s = string(val, base=16)
    lpad(s, 32, '0')
end

FilterNothings(thing) = filter(x -> x.second !== nothing, pairs(thing))
function MergeTags(args...)
    args = filter(!=(nothing), args)
    isempty(args) && return nothing
    out = merge(pairs.(args)...)
    isempty(out) && return nothing
    out
end

function PrepareBody(event::Event, buf)
    envelope_header = (; event.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    item = (;
            event.timestamp,
            event.platform,
            server_name = gethostname(),
            event.exception,
            event.message,
            event.level,
            main_hub.release,
            tags = MergeTags(global_tags, event.tags),
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="event",
                   content_type="application/json",
                   length=sizeof(item_str))


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)

    for attachment in event.attachments
        attachment_str = JSON.json((;data=attachment))
        attachment_header = (; type="attachment",
                             length=sizeof(attachment_str),
                             content_type="application/json")

        println(buf, JSON.json(attachment_header))
        println(buf, attachment_str)
    end


    nothing
end
function PrepareBody(transaction::Transaction, buf)
    envelope_header = (; transaction.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    if main_hub.debug && any(span -> span.timestamp === nothing, transaction.spans)
        @warn "At least one span didn't complete before the transaction completed"
    end

    spans = map(transaction.spans) do span
        (;
         transaction.trace_id,
         span.parent_span_id,
         span.span_id,
         span.tags,
         span.op,
         span.description,
         span.start_timestamp,
         span.timestamp)
    end
    #root_span = popfirst!(spans)
    # root_span = pop!(spans)
    root_span = transaction.root_span

    trace = (;
             transaction.trace_id,
             root_span.op,
             root_span.description,
             root_span.tags,
             root_span.span_id,
             root_span.parent_span_id,
            ) |> FilterNothings

    item = (; type="transaction",
            platform = "julia",
            server_name = gethostname(),
            transaction.event_id,
            transaction = transaction.name,
            # root_span...,
            root_span.start_timestamp,
            root_span.timestamp,
            tags = MergeTags(global_tags, root_span.tags),

            contexts = (; trace),
            spans = FilterNothings.(spans),
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="transaction",
                   content_type="application/json",
                   length=sizeof(item_str)+1) # +1 for the newline to come


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)
    nothing
end

# The envelope version
function send_envelope(task::TaskPayload)
    target = "$(main_hub.upstream)/api/$(main_hub.project_id)/envelope/"

    headers = ["Content-Type" => "application/x-sentry-envelope",
               "content-encoding" => "gzip",
               "User-Agent" => "SentryIntegration.jl/$VERSION",
               "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_client=SentryIntegration.jl/$VERSION, sentry_timestamp=$(nowstr()), sentry_key=$(main_hub.public_key)"
               ]

    buf = PipeBuffer()
    stream = CodecZlib.GzipCompressorStream(buf)
    PrepareBody(task, buf)
    body = read(stream)
    close(stream)

    if main_hub.dsn == "fake"
        body = String(transcode(CodecZlib.GzipDecompressor, body))
        lines = map(eachline(IOBuffer(body))) do line
            line = JSON.Parser.parse(line)
            line = JSON.json(line, 4)
        end
        @info "Would have sent event $(task.event_id)"
        foreach(println, lines)
        sleep(0.5)
        return
    end

    if main_hub.debug
        @info "Sending HTTP request for $(typeof(task))..."
    end
    r = HTTP.request("POST", target, headers, body)
    if main_hub.debug
        @info "Received response for $(typeof(task)); status = $(r.status)"
    end
    if r.status == 429
        # TODO
        @warn "Sentry: Too Many Requests"
    elseif r.status != 200
        # TODO
        @warn "Received error status = $(r.status)"
    end
    nothing
end

function send_worker()
    while true
        event = take!(main_hub.queued_tasks)
        main_hub.sending_tasks[event.event_id] = event
        yield()
        try
            send_envelope(event)
        catch ex
            if main_hub.debug
                @error "Error sending Sentry event"
                showerror(stderr, ex, catch_backtrace())
            end
        finally
            delete!(main_hub.sending_tasks, event.event_id)
        end
    end
end

function clear_queue()
    while isready(main_hub.queued_tasks) || !isempty(main_hub.sending_tasks)
        @info "Waiting for queue to finish before closing"
        sleep(1.0)
    end
end


####################################
# * Basic capturing
#----------------------------------

function capture_event(task::TaskPayload)
    main_hub.initialised || return

    put!(main_hub.queued_tasks, task)
end

function capture_message(message, level::LogLevel=Info ; kwds...)
    level_str = if level == Warn
        "warning"
    else
        lowercase(string(level))
    end
    capture_message(message, level_str ; kwds...)
end

function capture_message(message, level::String ; tags=nothing, attachments::Vector=[])
    main_hub.initialised || return

    capture_event(Event(;
                        message=(; formatted=message),
                        level,
                        attachments,
                        tags))
end

# This assumes that we are calling from within a catch
function capture_exception(exc::Exception; tags=nothing)
    capture_exception([(exc, catch_backtrace())]; tags)
end

function capture_exception(exceptions=catch_stack(); tags=nothing)
    main_hub.initialised || return

    formatted_excs = map(exceptions) do (exc,strace)
        bt = Base.scrub_repl_backtrace(strace)
        # frames = map(Base.stacktrace(strace, false)) do frame
        frames = map(bt) do frame
            Dict(:filename => frame.file,
             :function => frame.func,
             :lineno => frame.line)
        end

        Dict(:type => typeof(exc).name.name,
         :module => string(typeof(exc).name.module),
         :value => hasproperty(exc, :msg) ? exc.msg : sprint(showerror, exc),
         :stacktrace => (;frames=reverse(frames)))
    end
    capture_event(Event(;
                        exception=(;values=formatted_excs),
                        level="error",
                        tags))
end


end # module
