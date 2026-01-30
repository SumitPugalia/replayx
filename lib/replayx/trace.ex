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
  For message events, when `from` is a PID, includes `"from_node"` (sender node name) for distributed traces.
  """
  @spec event_to_map(event()) :: map()
  def event_to_map({:message, seq, kind, from, payload}) do
    base = %{
      "type" => "message",
      "seq" => seq,
      "kind" => to_string(kind),
      "from" => encode_term(from),
      "payload" => encode_term(payload)
    }

    from_node = sender_node(from)
    if from_node, do: Map.put(base, "from_node", from_node), else: base
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

  defp sender_node(pid) when is_pid(pid), do: node(pid) |> to_string()
  defp sender_node({pid, _}) when is_pid(pid), do: node(pid) |> to_string()
  defp sender_node(_), do: nil

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
    # Backward compat: infer call if from is tuple, else info; "from_node" if present is ignored
    from_dec = decode_term(from)
    kind = if is_tuple(from_dec) and tuple_size(from_dec) == 2, do: :call, else: :info
    {:message, seq, kind, from_dec, decode_term(payload)}
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
  Writes a trace to a file.
  Optional extra_metadata (e.g. %{"crash_reason" => "..."}) is merged into metadata.
  Options:
    * `:format` — `:json` (default) or `:binary` (ETF, smaller/faster).
    * `:gzip` — if `true`, compress the trace with gzip (smaller files; use `.json.gz` or `.etf.gz` extension).
  Returns `{:ok, :ok}` on success, or `{:error, reason}` on failure.
  """
  @spec write(String.t(), [event()], map() | nil, keyword()) :: {:ok, :ok} | {:error, term()}
  def write(path, events, extra_metadata \\ nil, opts \\ []) do
    format = Keyword.get(opts, :format, :json)
    gzip = Keyword.get(opts, :gzip, false)
    base = metadata()
    meta = if extra_metadata, do: Map.merge(base, extra_metadata), else: base

    contents =
      case format do
        :json -> build_json_content(meta, events)
        :binary -> build_binary_content(meta, events)
        _ -> build_json_content(meta, events)
      end

    to_write = if gzip, do: :zlib.gzip(contents), else: contents

    case File.write(path, to_write) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, {:file, reason}}
    end
  rescue
    e -> {:error, {:encode, e}}
  end

  defp build_json_content(meta, events) do
    doc = %{"metadata" => meta, "events" => Enum.map(events, &event_to_map/1)}
    Jason.encode!(doc, pretty: true)
  end

  defp build_binary_content(meta, events) do
    doc = %{metadata: meta, events: events}
    :erlang.term_to_binary(doc, compressed: 6)
  end

  @doc """
  Reads a trace from a file.
  Options:
    * `:format` — `:json`, `:binary`, or `:auto` (default; detect by content: 131 = ETF).
    * `:gzip` — if `true`, decompress with gzip first; if `:auto` (default), detect by gzip magic (1F 8B).
  Returns `{metadata, list of events}`.
  """
  @spec read(String.t(), keyword()) :: {map(), [event()]}
  def read(path, opts \\ []) do
    {:ok, bin} = File.read(path)
    bin = maybe_gunzip(bin, Keyword.get(opts, :gzip, :auto))
    format = Keyword.get(opts, :format, :auto)
    format = if format == :auto, do: detect_format(bin), else: format

    case format do
      :binary -> read_binary(bin)
      _ -> read_json(bin)
    end
  end

  # Gzip magic: 1F 8B
  defp maybe_gunzip(<<0x1F, 0x8B, _::binary>> = gzipped, :auto), do: :zlib.gunzip(gzipped)
  defp maybe_gunzip(bin, true), do: :zlib.gunzip(bin)
  defp maybe_gunzip(bin, _), do: bin

  defp detect_format(<<131, _::binary>>), do: :binary
  defp detect_format(_), do: :json

  defp read_json(bin) do
    doc = Jason.decode!(bin)
    meta = Map.get(doc, "metadata", %{})
    events = (doc["events"] || []) |> Enum.map(&map_to_event/1)
    {meta, events}
  end

  defp read_binary(bin) do
    %{metadata: meta, events: events} = :erlang.binary_to_term(bin)
    {meta, events}
  end

  @doc """
  Validates a trace file without full replay: checks it can be read and has metadata + events list.
  Returns `{:ok, :valid}` or `{:error, reason}`. Use to catch corrupt or incompatible traces early.
  """
  @spec valid?(String.t(), keyword()) :: {:ok, :valid} | {:error, term()}
  def valid?(path, opts \\ []) do
    case File.read(path) do
      {:ok, bin} ->
        bin = maybe_gunzip(bin, Keyword.get(opts, :gzip, :auto))
        format = Keyword.get(opts, :format, :auto)
        format = if format == :auto, do: detect_format(bin), else: format

        case format do
          :binary -> validate_binary(bin)
          _ -> validate_json(bin)
        end

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp validate_json(bin) do
    doc = Jason.decode!(bin)
    _ = Map.get(doc, "metadata", %{})
    events = doc["events"] || []
    if is_list(events), do: {:ok, :valid}, else: {:error, :invalid_events}
  rescue
    e -> {:error, {:decode, e}}
  end

  defp validate_binary(bin) do
    %{metadata: _meta, events: events} = :erlang.binary_to_term(bin)
    if is_list(events), do: {:ok, :valid}, else: {:error, :invalid_events}
  rescue
    e -> {:error, {:decode, e}}
  end

  @doc """
  Converts a PID to a filesystem-safe string (e.g. `#PID<0.123.0>` → `"0_123_0"`).
  Used in trace filenames so multiple instances of the same GenServer get distinct files.
  """
  @spec pid_to_filename_safe(pid()) :: String.t()
  def pid_to_filename_safe(pid) when is_pid(pid) do
    pid
    |> inspect()
    |> String.replace("<", "")
    |> String.replace(">", "")
    |> String.replace(".", "_")
    |> String.replace("#PID", "")
    |> String.trim_leading("_")
  end

  @doc """
  Builds a unique trace file path with timestamp for production (no overwrite on restart).
  Ensures directory exists. Uses ISO8601-style timestamp (colons replaced with `-` for filesystem safety).

  Options:
    * `:pid` – if set, the monitored process PID is included in the filename so multiple
      instances of the same GenServer get distinct trace files (e.g. `base_0_123_0_20260131T123456Z.json`).
  """
  @spec path_with_timestamp(String.t(), String.t(), keyword()) :: String.t()
  def path_with_timestamp(dir, base_prefix, opts \\ []) do
    File.mkdir_p!(dir)
    ts = DateTime.utc_now() |> DateTime.to_iso8601(:basic)

    name =
      case Keyword.get(opts, :pid) do
        pid when is_pid(pid) -> "#{base_prefix}_#{pid_to_filename_safe(pid)}_#{ts}.json"
        _ -> "#{base_prefix}_#{ts}.json"
      end

    Path.join(dir, name)
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
