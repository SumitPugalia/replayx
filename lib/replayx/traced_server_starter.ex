defmodule Replayx.TracedServerStarter do
  @moduledoc """
  Production helper: starts a Recorder + GenServer pair suitable for a DynamicSupervisor.

  When the GenServer crashes, the Recorder flushes the ring buffer to a trace file and exits.
  This starter process monitors both and exits when either exits, so the DynamicSupervisor
  can restart a new pair.

  ## Usage

  Add a DynamicSupervisor to your supervision tree:

      children = [
        {DynamicSupervisor, strategy: :one_for_one, name: MyApp.TracedWorkers},
        # ...
      ]

  Start a traced GenServer under it:

      Replayx.TracedServerStarter.start_child(MyApp.TracedWorkers, MyApp.MyServer)
      Replayx.TracedServerStarter.start_child(MyApp.TracedWorkers, MyApp.MyServer, [extra_arg], name: MyApp.MyServer)

  Your GenServer must:
  - `use Replayx.GenServer`
  - In `init`, handle `[recorder_pid | rest]` when `recorder_pid` is a pid: call
    `Replayx.Recorder.monitor(recorder_pid, self())` and put `replayx_recorder: recorder_pid` in state
  - Use `Replayx.Clock` and `Replayx.Rand` in callbacks for determinism

  ## Options (passed to `start_child/4`)

  - `:name` — registered name for the GenServer (e.g. `name: MyApp.MyServer`)
  - `:trace_buffer_size` — override the module's default (from `use Replayx.GenServer`)
  - `:trace_dir` — override the module's default
  - `:trace_rotation` — override the module's default
  - Any other option is passed to `GenServer.start_link/3` as options.
  """

  use GenServer

  @doc """
  Returns a child spec for use under a DynamicSupervisor.

  The server module must `use Replayx.GenServer` and its `init` must accept
  `[recorder_pid | server_init_args]` when recording (recorder_pid is a pid).

  ## Options

  - `:name` — registered name for the GenServer
  - `:trace_buffer_size`, `:trace_dir`, `:trace_rotation` — override module defaults
  - Any other option is passed to `GenServer.start_link/3`

  ## Examples

      DynamicSupervisor.start_child(MyApp.TracedWorkers, Replayx.TracedServerStarter.child_spec(MyApp.MyServer))
      DynamicSupervisor.start_child(MyApp.TracedWorkers, Replayx.TracedServerStarter.child_spec(MyApp.MyServer, [arg], name: MyApp.MyServer))
  """
  @spec child_spec(module(), list(), keyword()) :: Supervisor.child_spec()
  def child_spec(server_module, server_init_args \\ [], opts \\ []) do
    %{
      id: {__MODULE__, server_module, server_init_args, opts},
      start: {__MODULE__, :start_link, [server_module, server_init_args, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Starts a Recorder + GenServer pair under the given DynamicSupervisor.

  Equivalent to `DynamicSupervisor.start_child(sup, child_spec(server_module, server_init_args, opts))`.
  Returns `{:ok, pid}` where `pid` is this starter process (the GenServer pid is linked under it).
  """
  @spec start_child(Supervisor.supervisor(), module(), list(), keyword()) ::
          DynamicSupervisor.on_start_child_result()
  def start_child(supervisor, server_module, server_init_args \\ [], opts \\ []) do
    spec = child_spec(server_module, server_init_args, opts)
    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc """
  Starts the starter process (used by the child spec). Do not call directly;
  use `start_child/4` or add the child spec to a DynamicSupervisor.
  """
  @spec start_link(module(), list(), keyword()) :: GenServer.on_start()
  def start_link(server_module, server_init_args, opts) do
    GenServer.start_link(__MODULE__, {server_module, server_init_args, opts}, [])
  end

  @impl GenServer
  def init({server_module, server_init_args, opts}) do
    gen_server_opts = Keyword.take(opts, [:name, :timeout, :spawn_opt, :debug, :hibernate_after])
    replayx_overrides = Keyword.take(opts, [:trace_buffer_size, :trace_dir, :trace_rotation])

    recorder_opts =
      [
        dir: replayx_overrides[:trace_dir] || server_module.__replayx_trace_dir__(),
        base_prefix: server_module.__replayx_trace_base__(),
        buffer_size:
          replayx_overrides[:trace_buffer_size] || server_module.__replayx_trace_buffer_size__(),
        rotation: replayx_overrides[:trace_rotation] || server_module.__replayx_trace_rotation__()
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    base_prefix = server_module.__replayx_trace_base__()
    {:ok, recorder_pid} = Replayx.Recorder.start_link(base_prefix, recorder_opts)

    init_args = [recorder_pid | server_init_args]

    case GenServer.start_link(server_module, init_args, gen_server_opts) do
      {:ok, server_pid} ->
        ref = Process.monitor(server_pid)
        ref_rec = Process.monitor(recorder_pid)

        state = %{
          recorder_pid: recorder_pid,
          server_pid: server_pid,
          server_ref: ref,
          recorder_ref: ref_rec
        }

        {:ok, state}

      {:error, _} = err ->
        _ = Replayx.Recorder.stop(recorder_pid)
        {:stop, err}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      ref == state.server_ref ->
        # GenServer crashed; Recorder will receive DOWN, flush, then exit. Wait for Recorder DOWN so trace is written before we exit.
        {:noreply, %{state | server_ref: nil}}

      ref == state.recorder_ref ->
        # Recorder exited (after flush on server crash or normal stop). Now we can exit so supervisor can restart the pair.
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end
end
