defmodule FramerWebWeb.EditorLiveTest do
  use FramerWebWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the editor route renders the shell stub", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editor")

    assert html =~ "Framer Editor"
    assert has_element?(view, "#editor-shell")
    assert has_element?(view, "#editor-status")
  end
end
