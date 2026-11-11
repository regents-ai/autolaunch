# LiveViewTest's render_async/2 and assert_receive wait this long by default. Under
# load from other work on the same machine, ExUnit's 100 ms is too short.
ExUnit.start(exclude: [external: true], assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Autolaunch.Repo, :manual)

# Autolaunch.MarketTicker is one process for the whole application, and it reads
# the database on a timer and a second after any saved bid or trade. Under the
# sandbox such a read borrows whichever case's connection is shared at that
# moment, and that case can end mid-read. The ticker waits, suspended, except
# while a case runs it itself (AutolaunchWeb.QuietPagesTest), and pages still
# read its last list.
:ok = :sys.suspend(Autolaunch.MarketTicker)
