defmodule FramerWebWeb.Router do
  use FramerWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FramerWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FramerWebWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Rig/bones animation editor shell (milestones M3-M5 live behind this).
    live "/editor", EditorLive, :index
  end

  # Minimal JSON surface over the FramerCore orchestrator. The full control UI
  # is a separate, later task; this only proves the umbrella is wired together.
  scope "/api", FramerWebWeb do
    pipe_through :api

    get "/status", JobController, :status
    post "/jobs", JobController, :create
    get "/jobs/:id", JobController, :show

    # Editor rig surface: the versioned rig JSON is the contract with the
    # engine, and these routes persist it filesystem-first and drive the
    # existing `deform` operation (never shipping pixels to the BEAM).
    get "/rigs", RigController, :index
    post "/rigs", RigController, :create
    get "/rigs/:id", RigController, :show
    put "/rigs/:id", RigController, :update
    post "/rigs/:id/render", RigController, :render
    post "/rigs/:id/export", RigController, :export
    get "/rigs/:id/source", RigController, :source
    get "/rigs/:id/result", RigController, :result
  end

  # Other scopes may use custom stacks.
  # scope "/api", FramerWebWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:framer_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FramerWebWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
