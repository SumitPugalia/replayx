defmodule DivisorAppWeb.PageController do
  use DivisorAppWeb, :controller

  def home(conn, _params) do
    server_alive = Process.whereis(DivisorApp.DivisorGenServer) != nil
    plain_server_alive = Process.whereis(DivisorApp.PlainDivisorGenServer) != nil
    render(conn, :home, server_alive: server_alive, plain_server_alive: plain_server_alive)
  end

  def divide(conn, %{"divisor" => divisor_str}) do
    divisor = String.to_integer(divisor_str)

    conn =
      ensure_server_started(conn)
      |> do_divide(divisor)

    redirect(conn, to: ~p"/")
  end

  def divide(conn, _params) do
    put_flash(conn, :error, "Missing divisor") |> redirect(to: ~p"/")
  end

  def restart(conn, _params) do
    _ = maybe_start_divisor_server()
    put_flash(conn, :info, "Divisor server restarted.")
    redirect(conn, to: ~p"/")
  end

  def divide_plain(conn, %{"divisor" => divisor_str}) do
    divisor = String.to_integer(divisor_str)

    conn =
      ensure_plain_server_started(conn)
      |> do_divide_plain(divisor)

    redirect(conn, to: ~p"/")
  end

  def divide_plain(conn, _params) do
    put_flash(conn, :error, "Missing divisor") |> redirect(to: ~p"/")
  end

  def restart_plain(conn, _params) do
    _ = maybe_start_plain_divisor_server()
    put_flash(conn, :info, "Plain divisor server restarted.")
    redirect(conn, to: ~p"/")
  end

  defp ensure_server_started(conn) do
    if Process.whereis(DivisorApp.DivisorGenServer) == nil do
      maybe_start_divisor_server()
      put_flash(conn, :info, "Divisor server was down; restarted. Try again.")
    else
      conn
    end
  end

  defp do_divide(conn, divisor) do
    case GenServer.call(DivisorApp.DivisorGenServer, {:divide, divisor}, 5_000) do
      {:ok, result} ->
        put_flash(conn, :info, "10 / #{divisor} = #{result}")

      {:error, reason} ->
        put_flash(conn, :error, "Error: #{inspect(reason)}")
    end
  rescue
    _e ->
      msg =
        "Division by zero! Server crashed. Trace written to traces/. " <>
          "From divisor_app run: mix replay DivisorApp.DivisorGenServer"

      put_flash(conn, :error, msg)
  end

  defp ensure_plain_server_started(conn) do
    if Process.whereis(DivisorApp.PlainDivisorGenServer) == nil do
      maybe_start_plain_divisor_server()
      put_flash(conn, :info, "Plain divisor server was down; restarted. Try again.")
    else
      conn
    end
  end

  defp do_divide_plain(conn, divisor) do
    case GenServer.call(DivisorApp.PlainDivisorGenServer, {:divide, divisor}, 5_000) do
      {:ok, result} ->
        put_flash(conn, :info, "Plain: 10 / #{divisor} = #{result}")

      {:error, reason} ->
        put_flash(conn, :error, "Plain error: #{inspect(reason)}")
    end
  rescue
    _e ->
      msg =
        "Plain: division by zero! Server crashed. Trace in traces/. " <>
          "Replay: mix replay DivisorApp.PlainDivisorGenServer"

      put_flash(conn, :error, msg)
  end

  defp maybe_start_divisor_server do
    if Process.whereis(DivisorApp.DivisorGenServer) == nil do
      Replayx.TracedServerStarter.start_child(
        DivisorApp.TracedWorkers,
        DivisorApp.DivisorGenServer,
        [],
        name: DivisorApp.DivisorGenServer
      )
    end

    :ok
  end

  defp maybe_start_plain_divisor_server do
    if Process.whereis(DivisorApp.PlainDivisorGenServer) == nil do
      Replayx.TracedServerStarter.start_child(
        DivisorApp.PlainTracedWorkers,
        DivisorApp.PlainDivisorGenServer,
        [],
        name: DivisorApp.PlainDivisorGenServer
      )
    end

    :ok
  end
end
