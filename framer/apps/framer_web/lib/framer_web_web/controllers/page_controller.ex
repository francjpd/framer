defmodule FramerWebWeb.PageController do
  use FramerWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
