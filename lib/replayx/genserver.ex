defmodule Replayx.GenServer do
  @moduledoc """
  Instrumented GenServer that records or replays messages, time, and randomness.
  Use this instead of `use GenServer` when you want record/replay.

  Options (optional):
    * `:trace_file` – base trace filename for this GenServer. If not set, defaults to the module name (dots → underscores, lowercased) + `.json`.
    * `:trace_dir` – directory for timestamped trace files. Default `"traces"`.
    * `:trace_buffer_size` – number of events (and state snapshots) in the ring buffer. Default 10.
    * `:trace_rotation` – keyword list for rotation: `[max_files: 20]`, `[max_days: 7]`, or both. Default `[]`.
    * `:virtualize` – when your crash depends on time or randomness, set to `[:time, :rand]` (or `true` for both). With `:time`, the library records one monotonic time per message automatically (no call needed). With `:rand`, use the injected `uniform(n)` (or `Replayx.Rand`) where you need randomness. Optional: if your crash does not depend on time/rand, omit this.

  The library handles init for you: pass `[recorder_pid]` when starting (record mode)
  or the replayer passes `[{:replayx_replayer, agent_pid}]` (replay mode). Implement
  `init_impl/1` returning `{:ok, state}`; the library injects `replayx_recorder` or `replayx_replayer`.

  When `virtualize` includes `:time`, one monotonic time is recorded/consumed per message automatically.
  When it includes `:rand`, use the injected `uniform/1` or `Replayx.Rand` where you need randomness (instead of `:rand`).
  """

  @doc false
  defmacro __using__(opts) do
    explicit_trace_file = Keyword.get(opts || [], :trace_file)
    buffer_size = Keyword.get(opts || [], :trace_buffer_size, 10)
    trace_dir = Keyword.get(opts || [], :trace_dir, "traces")
    trace_rotation = Keyword.get(opts || [], :trace_rotation, [])
    virtualize = Keyword.get(opts || [], :virtualize, [])

    virtualize_list =
      case virtualize do
        true -> [:time, :rand]
        list when is_list(list) -> list
        _ -> []
      end

    time_macros =
      if :time in virtualize_list do
        quote do
          @doc false
          defmacro monotonic_time(unit \\ :native) do
            quote do: Replayx.Clock.monotonic_time(unquote(unit))
          end

          @doc false
          defmacro send_after(delay_ms, pid, msg) do
            quote do: Replayx.Clock.send_after(unquote(delay_ms), unquote(pid), unquote(msg))
          end
        end
      else
        []
      end

    rand_macros =
      if :rand in virtualize_list do
        quote do
          @doc false
          defmacro uniform do
            quote do: Replayx.Rand.uniform()
          end

          @doc false
          defmacro uniform(max) do
            quote do: Replayx.Rand.uniform(unquote(max))
          end
        end
      else
        []
      end

    quote do
      @replayx_virtualize unquote(virtualize_list)
      use GenServer

      unquote(time_macros)
      unquote(rand_macros)

      @doc false
      def __replayx_virtualize__, do: @replayx_virtualize

      @doc false
      def __replayx_trace_file__ do
        case unquote(explicit_trace_file) do
          nil ->
            __MODULE__
            |> to_string()
            |> String.replace_prefix("Elixir.", "")
            |> String.downcase()
            |> String.replace(".", "_")
            |> Kernel.<>(".json")

          path ->
            path
        end
      end

      @doc false
      def __replayx_trace_base__ do
        __replayx_trace_file__() |> String.replace_suffix(".json", "")
      end

      @doc false
      def __replayx_trace_dir__ do
        unquote(trace_dir)
      end

      @doc false
      def __replayx_trace_rotation__ do
        unquote(trace_rotation)
      end

      @doc false
      def __replayx_trace_buffer_size__ do
        unquote(buffer_size)
      end

      @doc false
      def init(args) do
        replayx_base =
          case args do
            [recorder_pid | _] when is_pid(recorder_pid) ->
              Replayx.Recorder.monitor(recorder_pid, self())
              %{replayx_recorder: recorder_pid}

            [{:replayx_replayer, agent_pid}] ->
              %{replayx_replayer: agent_pid}

            _ ->
              %{}
          end

        {:ok, user_state} = init_impl(args)
        {:ok, Map.merge(user_state, replayx_base)}
      end

      @doc """
      Returns your initial state. Override this; default is `{:ok, %{}}`.
      The library merges in `replayx_recorder` or `replayx_replayer` automatically.
      """
      def init_impl(_args), do: {:ok, %{}}

      def handle_call(msg, from, state) do
        Replayx.GenServer.instrument_call(__MODULE__, msg, from, state)
      end

      def handle_cast(msg, state) do
        Replayx.GenServer.instrument_cast(__MODULE__, msg, state)
      end

      def handle_info(msg, state) do
        Replayx.GenServer.instrument_info(__MODULE__, msg, state)
      end

      def handle_call_impl(msg, from, state), do: {:reply, :ok, state}
      def handle_cast_impl(msg, state), do: {:noreply, state}
      def handle_info_impl(msg, state), do: {:noreply, state}

      defoverridable init_impl: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_call_impl: 3,
                     handle_cast_impl: 2,
                     handle_info_impl: 2

      @after_compile Replayx.GenServer
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok | [term()]
  def __after_compile__(env, _binary) do
    virtualize = Module.get_attribute(env.module, :replayx_virtualize) || []

    if virtualize != [] do
      warn_if_direct_system_or_rand(env.module, virtualize)
    end
  end

  defp warn_if_direct_system_or_rand(module, virtualize) do
    callbacks = [:handle_call_impl, :handle_cast_impl, :handle_info_impl]

    for {name, arity} <- Enum.flat_map(callbacks, &list_definitions(module, &1)),
        clause <- get_clauses(module, name, arity),
        node <- find_system_or_rand_calls(clause, virtualize) do
      IO.warn(
        "Replayx: #{inspect(module)} uses virtualize #{inspect(virtualize)} but calls #{node} directly. " <>
          "Use Replayx.Clock / Replayx.Rand for deterministic replay.",
        Macro.Env.location(__ENV__)
      )
    end
  end

  defp list_definitions(module, :handle_call_impl) do
    case Module.get_definition(module, {:handle_call_impl, 3}, []) do
      nil -> []
      _ -> [{:handle_call_impl, 3}]
    end
  end

  defp list_definitions(module, :handle_cast_impl) do
    case Module.get_definition(module, {:handle_cast_impl, 2}, []) do
      nil -> []
      _ -> [{:handle_cast_impl, 2}]
    end
  end

  defp list_definitions(module, :handle_info_impl) do
    case Module.get_definition(module, {:handle_info_impl, 2}, []) do
      nil -> []
      _ -> [{:handle_info_impl, 2}]
    end
  end

  defp get_clauses(module, name, arity) do
    case Module.get_definition(module, {name, arity}, []) do
      nil -> []
      clauses when is_list(clauses) -> clauses
      single -> [single]
    end
  end

  defp find_system_or_rand_calls(quoted, virtualize) do
    acc = []

    Macro.prewalk(quoted, fn
      {{:., _, [mod, _fun]}, _, _} = node ->
        name = if is_atom(mod), do: mod, else: nil

        cond do
          name == System and :time in virtualize -> [:System | acc]
          name == :rand and :rand in virtualize -> [":rand" | acc]
          true -> acc
        end

        node

      node ->
        node
    end)
    |> case do
      {_, acc2} -> acc2
      _ -> []
    end
  end

  @doc false
  @spec instrument_call(module(), term(), term(), term()) :: term()
  def instrument_call(module, msg, from, state) do
    set_process_dict(state)
    maybe_record_message(state, :call, from, msg)
    maybe_consume_time(module)
    result = module.handle_call_impl(msg, from, state)
    maybe_record_state_snapshot(state, result, :call)
    result
  end

  @doc false
  @spec instrument_cast(module(), term(), term()) :: term()
  def instrument_cast(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :cast, nil, msg)
    maybe_consume_time(module)
    result = module.handle_cast_impl(msg, state)
    maybe_record_state_snapshot(state, result, :cast)
    result
  end

  @doc false
  @spec instrument_info(module(), term(), term()) :: term()
  def instrument_info(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :info, nil, msg)
    maybe_consume_time(module)
    result = module.handle_info_impl(msg, state)
    maybe_record_state_snapshot(state, result, :info)
    result
  end

  defp maybe_consume_time(module) do
    if :time in module.__replayx_virtualize__() do
      _ = Replayx.Clock.monotonic_time()
    end
  end

  defp set_process_dict(state) do
    if recorder = state[:replayx_recorder] do
      Process.put(:replayx_recorder, recorder)
      Process.delete(:replayx_replayer)
    end

    if replayer = state[:replayx_replayer] do
      Process.put(:replayx_replayer, replayer)
      Process.delete(:replayx_recorder)
    end
  end

  defp maybe_record_message(state, kind, from, payload) do
    case state[:replayx_recorder] do
      nil ->
        :ok

      recorder_pid ->
        seq = Replayx.Recorder.next_seq(recorder_pid)
        Replayx.Recorder.record_event(recorder_pid, {:message, seq, kind, from, payload})
    end
  end

  defp maybe_record_state_snapshot(state, result, _kind) do
    case state[:replayx_recorder] do
      nil ->
        :ok

      recorder_pid ->
        new_state = state_from_result(result)

        if new_state != nil,
          do: Replayx.Recorder.record_event(recorder_pid, {:state_snapshot, new_state})
    end
  end

  defp state_from_result({:reply, _reply, new_state}), do: new_state
  defp state_from_result({:reply, _reply, new_state, _timeout}), do: new_state
  defp state_from_result({:noreply, new_state}), do: new_state
  defp state_from_result({:noreply, new_state, _timeout}), do: new_state
  defp state_from_result({:stop, _reason, _reply, new_state}), do: new_state
  defp state_from_result({:stop, _reason, new_state}), do: new_state
  defp state_from_result(_), do: nil
end
