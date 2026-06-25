# Mox mocks for the integration ports. Each is selected as the adapter in
# config/test.exs so the domain talks to the mock instead of the real service.
Mox.defmock(Beatgrid.Audio.Mock, for: Beatgrid.Audio.Behaviour)
Mox.defmock(Beatgrid.Soundcharts.Mock, for: Beatgrid.Soundcharts.Client)
Mox.defmock(Beatgrid.AI.Mock, for: Beatgrid.AI.Client)
