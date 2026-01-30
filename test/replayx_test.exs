defmodule ReplayxTest do
  use ExUnit.Case, async: false

  alias Replayx.Examples.CrashingGenServer

  doctest Replayx

  describe "record and replay" do
    @tag :tmp_dir
    test "records messages and replays without crash", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trace.json")

      Replayx.record(path, fn recorder_pid ->
        {:ok, pid} = CrashingGenServer.start_link(recorder_pid)
        send(pid, :tick)
        send(pid, :tick)
        GenServer.call(pid, :state)
      end)

      assert File.exists?(path)
      assert {:ok, _state} = Replayx.replay(path, CrashingGenServer)
    end

    @tag :tmp_dir
    test "replay reproduces crash when trace ends in crash", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trace_crash.json")

      Replayx.record(path, fn recorder_pid ->
        {:ok, pid} = CrashingGenServer.start_link(recorder_pid)
        Process.unlink(pid)
        ref = Process.monitor(pid)
        send(pid, :tick)
        send(pid, :crash)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end)

      assert_raise RuntimeError, ~r/replayx example crash/, fn ->
        Replayx.replay(path, CrashingGenServer)
      end
    end
  end

  describe "Trace" do
    test "encode_term and decode_term roundtrip" do
      term = %{pid: self(), ref: make_ref(), x: 1}
      encoded = Replayx.Trace.encode_term(term)
      assert is_binary(encoded)
      assert Replayx.Trace.decode_term(encoded) == term
    end

    test "event_to_map and map_to_event roundtrip" do
      event = {:message, 1, :info, nil, :hello}
      map = Replayx.Trace.event_to_map(event)
      assert map["type"] == "message"
      assert Replayx.Trace.map_to_event(map) == event
    end

    test "write returns {:error, _} when path is not writable" do
      # Path under nonexistent directory causes file error (e.g. ENOENT on Unix)
      path = "/nonexistent/replayx_test/trace.json"
      assert {:error, {:file, _reason}} = Replayx.Trace.write(path, [], nil)
    end

    @tag :tmp_dir
    test "write returns {:ok, :ok} on success", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trace.json")
      assert {:ok, :ok} = Replayx.Trace.write(path, [{:time_monotonic, 1}], nil)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "binary format roundtrip (write and read :auto)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trace.etf")
      events = [{:time_monotonic, 1}, {:message, 0, :info, nil, :hello}]
      assert {:ok, :ok} = Replayx.Trace.write(path, events, nil, format: :binary)
      assert File.exists?(path)
      {_meta, read_events} = Replayx.Trace.read(path, format: :auto)
      assert read_events == events
    end
  end

  describe "Recorder" do
    @tag :tmp_dir
    test "writes trace file on stop", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rec.json")
      {:ok, pid} = Replayx.Recorder.start_link(path)
      Replayx.Recorder.record_event(pid, {:time_monotonic, 123})
      Replayx.Recorder.stop(pid)
      assert File.exists?(path)
      {_meta, events} = Replayx.Trace.read(path)
      assert events == [{:time_monotonic, 123}]
    end
  end

  describe "Telemetry" do
    @tag :tmp_dir
    test "emits trace_written when recorder flushes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "telemetry_trace.json")
      id = "replayx-test-trace-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        id,
        [:replayx, :recorder, :trace_written],
        fn _name, measurements, metadata, _config ->
          send(parent, {:trace_written, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Replayx.Recorder.start_link(path)
      Replayx.Recorder.record_event(pid, {:time_monotonic, 1})
      Replayx.Recorder.stop(pid)

      assert_receive {:trace_written, %{event_count: 1}, %{path: ^path, crash_reason: nil}}
      :telemetry.detach(id)
    end

    test "emits trace_write_failed when trace write fails" do
      path = "/nonexistent/replayx_test/rec.json"
      id = "replayx-test-write-fail-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        id,
        [:replayx, :recorder, :trace_write_failed],
        fn _name, measurements, metadata, _config ->
          send(parent, {:trace_write_failed, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Replayx.Recorder.start_link(path)
      Replayx.Recorder.record_event(pid, {:time_monotonic, 1})
      Replayx.Recorder.stop(pid)

      assert_receive {:trace_write_failed, %{event_count: 1}, %{path: ^path, reason: {:file, _}}}
      :telemetry.detach(id)
    end

    @tag :tmp_dir
    test "emits replayer start and stop on replay", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replay_telemetry.json")

      Replayx.record(path, fn recorder_pid ->
        {:ok, pid} = CrashingGenServer.start_link(recorder_pid)
        send(pid, :tick)
        # wait for tick to be processed
        GenServer.call(pid, :state)
        Replayx.Recorder.stop(recorder_pid)
      end)

      id_start = "replayx-test-start-#{System.unique_integer([:positive])}"
      id_stop = "replayx-test-stop-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        id_start,
        [:replayx, :replayer, :start],
        fn _name, _m, metadata, _config ->
          send(parent, {:replay_start, metadata})
        end,
        nil
      )

      :telemetry.attach(
        id_stop,
        [:replayx, :replayer, :stop],
        fn _name, _m, metadata, _config ->
          send(parent, {:replay_stop, metadata})
        end,
        nil
      )

      assert {:ok, _} = Replayx.replay(path, CrashingGenServer)

      assert_receive {:replay_start, %{path: ^path, module: CrashingGenServer}}
      assert_receive {:replay_stop, %{path: ^path, module: CrashingGenServer, result: {:ok, _}}}

      :telemetry.detach(id_start)
      :telemetry.detach(id_stop)
    end
  end
end
