defmodule BeatgridWeb.ServiceWorkerController do
  @moduledoc """
  Handles stray `GET /sw.js` requests.

  Beatgrid ships no PWA / service worker, but a browser that once ran a
  different app on this `localhost` port can keep a registered service worker
  for the origin. It polls `/sw.js` forever, and without a route Phoenix raises
  `NoRouteError` on each hit (noisy stacktraces in dev).

  Instead of 404-ing, we serve a tiny worker that unregisters itself, so the
  zombie tears itself down on its next update check and stops re-fetching.
  """
  use BeatgridWeb, :controller

  @worker """
  self.addEventListener("install", () => self.skipWaiting());
  self.addEventListener("activate", (event) => {
    event.waitUntil(
      self.registration
        .unregister()
        .then(() => self.clients.matchAll())
        .then((clients) => clients.forEach((client) => client.navigate(client.url)))
    );
  });
  """

  def unregister(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> send_resp(200, @worker)
  end
end
