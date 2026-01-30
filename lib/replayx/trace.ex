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
  """
  @spec write(String.t(), [event()]) :: :ok
  def write(path, events) do
    doc = %{
      "metadata" => metadata(),
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
end
