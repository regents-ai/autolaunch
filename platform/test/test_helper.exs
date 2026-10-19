ExUnit.start(exclude: [external: true])
Ecto.Adapters.SQL.Sandbox.mode(Autolaunch.Repo, :manual)

# Autolaunch.MarketTicker is one process for the whole application, and it reads
# the database on a timer and a second after any saved bid or trade. Under the
# sandbox such a read borrows whichever case's connection is shared at that
# moment, and that case can end mid-read. The ticker waits, suspended, except
# while a case runs it itself (AutolaunchWeb.QuietPagesTest), and pages still
# read its last list.
:ok = :sys.suspend(Autolaunch.MarketTicker)
