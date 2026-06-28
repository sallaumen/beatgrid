defmodule BeatgridWeb.ServiceWorkerControllerTest do
  use BeatgridWeb.ConnCase, async: true

  test "GET /sw.js serves a self-unregistering service worker instead of 404", %{conn: conn} do
    conn = get(conn, ~p"/sw.js")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "javascript"
    # The worker tears itself down so the browser stops re-fetching /sw.js.
    assert conn.resp_body =~ "unregister"
  end
end
