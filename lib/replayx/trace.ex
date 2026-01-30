defmodule Replayx.Trace do
  @moduledoc """
  Trace file format: JSON with metadata and a sequence of events.
  Payloads and pids are stored as Base64-encoded Erlang terms.
  """

  @type message_kind :: :call | :cast | :info
  @type event ::
          {:message, non_neg_integer(), message_kind(), term(), term()}
          | {:time_monotonic, integer()}
          | {:time_system, integer()}
          | {:rand, float()}
          | {:rand_seed, {integer(), integer(), integer()}}
          | {:send_after, reference(), non_neg_integer()}
          | {:state_snapshot, term()}

  @doc """
  Encodes a term for JSON storage (Base64 of term_to_binary).
  """
  @spec encode_term(term()) :: String.t()
  def encode_term(term) do
    term |> :erlang.term_to_binary() |> Base.encode64()
  end

  @doc """
  Decodes a term from JSON storage.
  """
  @spec decode_term(String.t()) :: term()
  def decode_term(string) do
    string |> Base.decode64!() |> :erlang.binary_to_term()
  end

  @doc """
  Converts an event tuple to a JSON-serializable map.
  """
  @spec event_to_map(event()) :: map()
  def event_to_map({:message, seq, kind, from, payload}) do
    %{
      "type" => "message",
      "seq" => seq,
      "kind" => to_string(kind),
      "from" => encode_term(from),
      "payload" => encode_term(payload)
    }
  end

  def event_to_map({:time_monotonic, value}) do
    %{"type" => "time_monotonic", "value" => value}
  end

  def event_to_map({:time_system, value}) do
    %{"type" => "time_system", "value" => value}
  end

  def event_to_map({:rand, value}) do
    %{"type" => "rand", "value" => value}
  end

  def event_to_map({:rand_seed, {a, b, c}}) do
    %{"type" => "rand_seed", "seed" => [a, b, c]}
  end

  def event_to_map({:send_after, ref, delay_ms}) do
    %{"type" => "send_after", "ref" => encode_term(ref), "delay_ms" => delay_ms}
  end

  def event_to_map({:state_snapshot, state}) do
    %{"type" => "state_snapshot", "state" => encode_term(state)}
  end

  @doc """
  Converts a JSON map back to an event tuple.
  """
  @spec map_to_event(map()) :: event()
  def map_to_event(%{
        "type" => "message",
        "seq" => seq,
        "kind" => kind,
        "from" => from,
        "payload" => payload
      }) do
    kind_atom =
      case kind do
        "call" -> :call
        "cast" -> :cast
        "info" -> :info
        _ -> :info
      end

    {:message, seq, kind_atom, decode_term(from), decode_term(payload)}
  end

  def map_to_event(%{"type" => "message", "seq" => seq, "from" => from, "payload" => payload}) do
    # Backward compat: infer call if from is tuple, else info
    kind = if is_tuple(from) and tuple_size(from) == 2, do: :call, else: :info
    {:message, seq, kind, decode_term(from), decode_term(payload)}
  end

  def map_to_event(%{"type" => "time_monotonic", "value" => value}) do
    {:time_monotonic, value}
  end

  def map_to_event(%{"type" => "time_system", "value" => value}) do
    {:time_system, value}
  end

  def map_to_event(%{"type" => "rand", "value" => value}) do
    {:rand, value}
  end

  def map_to_event(%{"type" => "rand_seed", "seed" => [a, b, c]}) do
    {:rand_seed, {a, b, c}}
  end

  def map_to_event(%{"type" => "send_after", "ref" => ref, "delay_ms" => delay_ms}) do
    {:send_after, decode_term(ref), delay_ms}
  end

  def map_to_event(%{"type" => "state_snapshot", "state" => state}) do
    {:state_snapshot, decode_term(state)}
  end

  @doc """
  Builds metadata map for the trace (Elixir version, node).
  """
  @spec metadata() :: map()
  def metadata do
    %{
      "elixir" => System.version(),
      "node" => node() |> to_string()
    }
  end

  @doc """
  Writes a trace to a JSON file.
  Optional extra_metadata (e.g. %{"crash_reason" => "..."}) is merged into metadata.
  """
  @spec write(String.t(), [event()], map() | nil) :: :ok
  def write(path, events, extra_metadata \\ nil) do
    base = metadata()
    meta = if extra_metadata, do: Map.merge(base, extra_metadata), else: base

    doc = %{
      "metadata" => meta,
      "events" => Enum.map(events, &event_to_map/1)
    }

    File.write!(path, Jason.encode!(doc, pretty: true))
    :ok
  end

  @doc """
  Reads a trace from a JSON file. Returns {metadata, list of events}.
  """
  @spec read(String.t()) :: {map(), [event()]}
  def read(path) do
    {:ok, bin} = File.read(path)
    doc = Jason.decode!(bin)
    metadata = Map.get(doc, "metadata", %{})
    events = (doc["events"] || []) |> Enum.map(&map_to_event/1)
    {metadata, events}
  end

  @doc """
  Builds a unique trace file path with timestamp for production (no overwrite on restart).
  Ensures directory exists. Uses ISO8601-style timestamp (colons replaced with `-` for filesystem safety).
  """
  @spec path_with_timestamp(String.t(), String.t()) :: String.t()
  def path_with_timestamp(dir, base_prefix) do
    File.mkdir_p!(dir)
    ts = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    Path.join(dir, "#{base_prefix}_#{ts}.json")
  end

  @doc """
  Rotates trace files in `dir` matching `base_prefix_*.json`.
  Options (keyword list):
    * `:max_files` – keep at most this many newest files; delete older (default: no limit).
    * `:max_days` – delete files older than this many days (default: no limit).
  """
  @spec rotate(String.t(), String.t(), keyword()) :: :ok
  def rotate(dir, base_prefix, opts \\ []) do
    max_files = Keyword.get(opts, :max_files)
    max_days = Keyword.get(opts, :max_days)

    if is_nil(max_files) and is_nil(max_days) do
      :ok
    else
      apply_rotation(dir, base_prefix, max_files, max_days)
    end
  end

  defp apply_rotation(dir, base_prefix, max_files, max_days) do
    pattern = Path.join(dir, "#{base_prefix}_*.json")
    files = Path.wildcard(pattern)
    if files == [], do: :ok, else: delete_old_files(files, max_files, max_days)
  end

  defp delete_old_files(files, max_files, max_days) do
    cutoff_time =
      max_days &&
        DateTime.utc_now()
        |> DateTime.add(-max_days, :day)
        |> DateTime.to_unix()

    with_mtime =
      Enum.map(files, fn f ->
        {:ok, stat} = File.stat(f, time: :posix)
        {f, stat.mtime}
      end)

    sorted = Enum.sort_by(with_mtime, fn {_, mtime} -> mtime end, :desc)
    to_keep_count = max_files || length(sorted)
    kept = Enum.take(sorted, to_keep_count)
    beyond_count = Enum.drop(sorted, to_keep_count)

    old_kept =
      if cutoff_time,
        do: Enum.filter(kept, fn {_, mtime} -> mtime < cutoff_time end),
        else: []

    to_delete = beyond_count ++ old_kept
    Enum.each(to_delete, fn {path, _} -> File.rm(path) end)
    :ok
  end

  @doc """
  Builds a human-readable summary of the trace: each message event paired with the state after it.
  Used by replay CLI to show the last N events and states from the ring buffer.
  """
  @spec summary([event()]) :: [String.t()]
  def summary(events) do
    pairs = pair_messages_with_state(events)
    count = length(pairs)
    header = ["Trace summary (#{count} message(s) from ring buffer):", ""]

    lines =
      Enum.map(pairs, fn {seq, kind, payload, state_after} ->
        payload_str = inspect(payload)
        state_str = if state_after, do: inspect(state_after), else: "(crash, no state)"
        "  seq #{seq} | #{kind} | #{payload_str} → state: #{state_str}"
      end)

    header ++ lines
  end

  defp pair_messages_with_state(events) do
    events
    |> Enum.reduce({[], nil}, fn
      {:message, seq, kind, _from, payload}, {acc, _} ->
        {[{seq, kind, payload, nil} | acc], {seq, kind, payload}}

      {:state_snapshot, state}, {[{seq, kind, payload, nil} | rest], _} ->
        {[{seq, kind, payload, state} | rest], nil}

      {:state_snapshot, _}, {acc, _} ->
        {acc, nil}

      _, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Returns the path to the newest trace file in `dir` matching `base_prefix_*.json`, or nil if none.
  Used by `replay(module)` to pick the latest trace when using timestamped rotation.
  """
  @spec latest_path(String.t(), String.t()) :: String.t() | nil
  def latest_path(dir, base_prefix) do
    pattern = Path.join(dir, "#{base_prefix}_*.json")

    Path.wildcard(pattern)
    |> Enum.sort_by(
      fn f ->
        {:ok, stat} = File.stat(f, time: :posix)
        stat.mtime
      end,
      :desc
    )
    |> List.first()
  end
end
