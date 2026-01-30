defmodule ReplayxTracePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Replayx.Trace

  # Serializable term: scalars + trees of lists/maps (no pids/refs/ports).
  defp serializable_term do
    leaf =
      StreamData.one_of([
        StreamData.atom(:alphanumeric),
        StreamData.integer(),
        StreamData.float(),
        StreamData.binary()
      ])

    StreamData.tree(leaf, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 5),
        StreamData.map_of(child, child, max_length: 4)
      ])
    end)
  end

  property "encode_term and decode_term roundtrip for serializable terms" do
    check all(term <- serializable_term()) do
      encoded = Trace.encode_term(term)
      assert is_binary(encoded)
      assert Trace.decode_term(encoded) == term
    end
  end

  property "event_to_map and map_to_event roundtrip for message events" do
    check all(
            seq <- StreamData.integer(0..1_000_000),
            kind <- StreamData.member_of([:call, :cast, :info]),
            from <- serializable_term(),
            payload <- serializable_term()
          ) do
      event = {:message, seq, kind, from, payload}
      map = Trace.event_to_map(event)
      assert map["type"] == "message"
      assert Trace.map_to_event(map) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for time_monotonic" do
    check all(value <- integer()) do
      event = {:time_monotonic, value}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for time_system" do
    check all(value <- integer()) do
      event = {:time_system, value}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for rand" do
    check all(value <- float()) do
      event = {:rand, value}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for rand_seed" do
    check all(a <- integer(), b <- integer(), c <- integer()) do
      event = {:rand_seed, {a, b, c}}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for send_after" do
    check all(ref <- serializable_term(), delay_ms <- StreamData.integer(0..1_000_000)) do
      event = {:send_after, ref, delay_ms}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  property "event_to_map and map_to_event roundtrip for state_snapshot" do
    check all(state <- serializable_term()) do
      event = {:state_snapshot, state}
      assert Trace.map_to_event(Trace.event_to_map(event)) == event
    end
  end

  @tag :tmp_dir
  property "write and read roundtrip (JSON) preserves events", %{tmp_dir: tmp_dir} do
    check all(events <- list_of(message_event(), max_length: 8)) do
      path = Path.join(tmp_dir, "prop_#{System.unique_integer([:positive])}.json")
      assert {:ok, :ok} = Trace.write(path, events, nil, format: :json)
      {_meta, read_events} = Trace.read(path, format: :json)
      assert read_events == events
    end
  end

  @tag :tmp_dir
  property "write and read roundtrip (binary) preserves events", %{tmp_dir: tmp_dir} do
    check all(events <- list_of(message_event(), max_length: 8)) do
      path = Path.join(tmp_dir, "prop_#{System.unique_integer([:positive])}.etf")
      assert {:ok, :ok} = Trace.write(path, events, nil, format: :binary)
      {_meta, read_events} = Trace.read(path, format: :binary)
      assert read_events == events
    end
  end

  defp message_event do
    StreamData.tuple({
      serializable_term(),
      serializable_term(),
      StreamData.integer(0..1_000_000),
      StreamData.member_of([:call, :cast, :info])
    })
    |> StreamData.map(fn {from, payload, seq, kind} -> {:message, seq, kind, from, payload} end)
  end
end
