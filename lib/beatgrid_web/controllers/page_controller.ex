defmodule BeatgridWeb.PageController do
  use BeatgridWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
