-module(trade_calls).

-compile(export_all).

main_bid() ->
    S = self(),
    PidCliBid = spawn(fun () -> bidA(S) end),
    receive PidBid -> PidBid end,
    spawn(fun () -> bidB(PidBid, PidCliBid) end).

bidA(Parent) -> %producer
    {ok, Pid} = trade_fsm:start_link("Michal"),
    Parent ! Pid,
    io:format("Spawned Michal: ~p~n", [Pid]),
    timer:sleep(800),
    trade_fsm:accept_trade(Pid),
    timer:sleep(400),
    io:format("Michal synchronizing~n"),
    sync2(),
    timer:sleep(100),
    trade_fsm:accept_bidding(Pid),
    timer:sleep(300),
    trade_fsm:make_price(Pid, 40),
    timer:sleep(200),
    trade_fsm:ready(Pid),
    timer:sleep(200),
    timer:sleep(1000).

bidB(PidBid,
     PidCliBid) -> %consumer
    {ok, Pid} = trade_fsm:start_link("Kamil"),
    io:format("Spawned Kamil: ~p~n", [Pid]),
    timer:sleep(500),
    trade_fsm:trade(Pid, PidBid),
    trade_fsm:make_offer(Pid, "boots"),
    timer:sleep(200),
    io:format("Kamil synchronizing~n"),
    sync1(PidCliBid),
    trade_fsm:bidding(Pid, PidBid),
    timer:sleep(150),
    trade_fsm:make_price(Pid, 30),
    timer:sleep(400),
    trade_fsm:make_price(Pid, 45),
    timer:sleep(200),
    trade_fsm:ready(Pid),
    timer:sleep(200),
    timer:sleep(1000).

%%% Utils
sync1(Pid) -> Pid ! self(), receive ack -> ok end.

sync2() -> receive From -> From ! ack end.
