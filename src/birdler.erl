%% vim: ts=4 sw=4 sts=4 et

-module(birdler).
-behaviour(gen_server).

%-compile(export_all).

-define(TIMEOUT,get_env(timeout, 300)).
-define(API_KEY, get_env(api_key, "")).
-define(API_PREFIX,get_env(api_prefix, "https://us1.platform.bird.com/v1")).
-define(EMAIL_ENDPOINT, get_env(email_endpoint, "/email/messages")).
-define(SMS_ENDPOINT, get_env(email_endpoint, "/sms/messages")).
-define(HTTP_OPTIONS, []).
-define(OPTIONS, [{full_result,false}]).

-export([
    start_link/0,
    init/1,
    stop/0,
    reset/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    status/0,
    code_change/3
]).

-export([
    email/1,
    email/4,
    email/5,
    email/6,
    sms/1,
    sms/3,
    sms/4
]).

-export([fix_floating_linefeeds/1]).

-record(mail,{from,to,subject,text,html,options}).
-record(sms,{from, to, text, category}).
-record(data,{queue}).

get_env(Key, Default) ->
    case application:get_env(birdler, Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.

sms(SMS = #{from:=From,
            to:=To,
            text:=Text}) ->
    Category = maps:get(category, SMS, marketing),
    Msg = #sms{
        from=From,
        to=To,
        text=Text,
        category=Category},
    gen_server:call(?MODULE, {queue, Msg}).


sms(From, To, Text) ->
    sms(From, To, Text, marketing).

sms(From, To, Text, Category) ->
    sms(#{from=>From,
          to=>To,
          text=>Text,
          category=>Category}).


email(#{from:=From,
        to:=To,
        subject:=Subject,
        text:=Text,
        html:=Html,
        options:=Options}) ->
    Mail = #mail{
        to=To,
        from=From,
        subject=Subject,
        text=Text,
        html=Html,
        options=Options
    },
    gen_server:call(?MODULE,{queue,Mail}).

%% kept for backwards compatibitlity only
email(From,To,Subject,Text) ->
    email(From,To,Subject,Text,[],[]).

email(From,To,Subject,Text,Html) ->
    email(From,To,Subject,Text,Html,[]).
email(From,To,Subject,Text,Html,Options) ->
    email(#{
        from=>From,
        to=>To,
        subject=>Subject,
        text=>Text,
        html=>Html,
        options=>Options
    }).

start_link() ->
    gen_server:start_link({local,?MODULE},?MODULE,#data{},[]).

stop() ->
    gen_server:call(?MODULE,stop).

reset() ->
    gen_server:call(?MODULE,reset).

status() ->
    gen_server:call(?MODULE,status).

terminate(_Reason,_Data) ->
    ok.

init(Data) ->
    {ok,Data#data{queue=queue:new()},?TIMEOUT}.

handle_call({queue,Msg},_From,#data{queue=Queue} = Data) ->
    NewQueue = queue:in(Msg,Queue),
    NewLen = queue:len(NewQueue),
    {reply,{queued,NewLen},Data#data{queue=NewQueue},?TIMEOUT};
handle_call(reset,_From,Data) ->
    {reply,ok,Data#data{queue=queue:new()},?TIMEOUT};
handle_call(status,_From,#data{queue=Queue} = Data) ->
    Len = queue:len(Queue),
    Status = [
        {queue_size,Len}
    ],
    {reply,Status,Data,?TIMEOUT};
handle_call(stop,_From,Data) ->
    {stop,stopped,Data}.

handle_info(timeout,#data{queue=Queue} = Data) ->
    NewQueue = case queue:out(Queue) of
        {{value,Mail=#mail{}},NQ} ->
            #mail{
                from=From,
                to=To,
                subject=Subject,
                text=Text,
                html=Html,
                options=Options
            } = Mail,
            spawn(fun() ->
                try
                    send_inner(email,?API_KEY,?API_PREFIX,From,To,Subject,Text,Html,Options)
                catch E:T:S ->
                    logger:error("Email Error: ~p:~p~n~p~n",[E,T,S])
                end
            end),
            NQ;
        {{value,SMS=#sms{}},NQ} ->
            #sms{
                from=From,
                to=To,
                text=Text,
                category=Category
            } = SMS,
            Options = [{category, Category}],
            spawn(fun() ->
                try
                    send_inner(sms,?API_KEY,?API_PREFIX,From,To,"",Text,"",Options)
                catch E:T:S ->
                    logger:error("SMS Error: ~p:~p~n~p~n",[E,T,S])
                end
            end),
            NQ;
        {empty,Queue} ->
            Queue
    end,
    {noreply,Data#data{queue=NewQueue},?TIMEOUT}.

handle_cast(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

send_inner(Type, APIKey, Prefix, From, To, Sub, Text, Html, Options) ->
    send_inner(5, Type, APIKey, Prefix, From, To, Sub, Text, Html, Options).

send_inner(0,Type,APIKey,Prefix,From,To,Sub,_Text,_Html,_Options) ->
    logger:error([
        failed_send,
        {send_type, Type},
        {api_key,APIKey},
        {prefix,Prefix},
        {from,From},
        {to,To},
        {subject,Sub}
    ]);
send_inner(TryNum,Type,_APIKey,Prefix,From,To,Subject,Text,Html,Options) when TryNum > 0 ->
    URL = Prefix ++ url(Type),
    EncodedJson = make_json(Type, From, To, Subject, Text, Html, Options),
    Body = iolist_to_binary(EncodedJson),
    Headers = auth_headers(),
    IbrowseOptions = ibrowse_opts(),

    logger:notice("Sending: ~nHeaders: ~p~nURL: ~s~nMessage: ~s~n", [Headers, URL, Body]),
    
    case ibrowse:send_req(URL,Headers,post,Body,IbrowseOptions) of
        {ok, _, _, Result} ->
            case maybe_decode_json(Result) of
                #{<<"error">> := Error} ->
                    logger:error("Failed to send: ~p", [Error]);
                Success ->
                    logger:notice("Sent: ~p~n",[Success])
            end,
            do_nothing;
        {error, Reason} ->
            logger:error("Error Sending: ~p~n",[maybe_decode_json(Reason)])
    end.

maybe_decode_json(X) ->
    try jsx:decode(i2b(X))
    catch E:T:S ->
        logger:warning("Inbvalid JSON: ~p:~p~n~p~n",[E,T,S]),
        X
    end.

url(email) ->
    ?EMAIL_ENDPOINT;
url(sms) ->
    ?SMS_ENDPOINT.


auth_headers() ->
    [
        {authorization, i2b(["Bearer ", ?API_KEY])},
        {content_type,"application/json"}
    ].

ibrowse_opts() ->
    [
        {content_type,"application/json"},
        {ssl_options, [{verify, verify_none}]}
    ].

make_json(email, From, To, Subject, Text, Html, Options) ->
    {Options2, ReplyTo} = extract_option(reply_to, Options),
    {_Options3, Category} = extract_option(category, Options2),
    ReplyToOption = create_option(reply_to, ReplyTo),
    HtmlOption = create_option(html, Html),
    CategoryOption = create_option(category, Category),
    {FromName, FromEmail} = normalize_email_name(From),
    {ToName, ToEmail} = normalize_email_name(To),
    Proplist =
    [
        {text, i2b(Text)},
        {subject, i2b(Subject)},
        {from, [{email, i2b(FromEmail)}, {name, i2b(FromName)}]},
        {to, [
            [{email,i2b(ToEmail)},{name,i2b(ToName)}]
        ]},
        {track_clicks, false}
    ] ++ ReplyToOption ++ HtmlOption ++ CategoryOption,
    jsx:encode(Proplist);
make_json(sms, From, To, _Subject, Text, _Html, Options) ->
    {_Options3, Category} = extract_option(category, Options),
    CategoryOption = create_option(category, Category),
    Proplist =
    [
        {text, i2b(Text)},
        {from, i2b(From)},
        {to, i2b(To)}
    ] ++ CategoryOption,
    jsx:encode(Proplist).

create_option(_Option, Value) when Value == <<>>;
                                      Value == "";
                                      Value == undefined ->
    [];
create_option(Option, Value) ->
    [{Option, i2b(Value)}]. 

extract_option(Opt, Options) ->
    Opt2 = normalized_header(Opt),
    extract_option_worker(Opt2, Options).

extract_option_worker(OptName, Options) ->
    lists:foldl(fun({K,V}, {OptAcc, FoundVal}) ->
        NormHead = normalized_header(K),
        case NormHead == OptName of
            true -> {OptAcc, V};
            false -> {[{K,V}|OptAcc], FoundVal}
        end
    end, {[], undefined}, Options).


normalized_header(H) when is_atom(H) ->
    normalized_header(atom_to_list(H));
normalized_header(H) when is_list(H) ->
    H2 = re:replace(H, "[^a-zA-Z0-9]", "", [{return, list}]),
    string:to_lower(H2).

normalize_email_name(#{name:=Name, email:=Email}) ->
    {Name, Email};
normalize_email_name({FromName, FromEmail}) ->
    {FromName, FromEmail};
normalize_email_name(EmailString) ->
    case re:run(EmailString, "^\"(.*)\"\s*<(.*@.*)>$", [{capture, all_but_first, list}]) of
        {match, [Name, Email]} -> {Email, Name};
        nomatch -> {EmailString, EmailString}
    end.

fix_floating_linefeeds([]) ->
    [];
fix_floating_linefeeds([13,10 | Text]) ->
    [13,10 | fix_floating_linefeeds(Text)];
fix_floating_linefeeds([13 | Text]) ->
    [13,10 | fix_floating_linefeeds(Text)];
fix_floating_linefeeds([10 | Text]) ->
    [13,10 | fix_floating_linefeeds(Text)];
fix_floating_linefeeds([H | Text]) ->
    [H | fix_floating_linefeeds(Text)].

i2b(A) when is_atom(A) ->
    i2b(atom_to_list(A));
i2b(IO) ->
    unicode:characters_to_binary(IO).
