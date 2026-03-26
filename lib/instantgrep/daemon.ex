defmodule Instantgrep.Daemon do
  @moduledoc """
  Background daemon listening on a Unix domain socket for fast CLI queries.
  """

  require Logger

  def start_server do
    socket_path = get_socket_path()

    # Ensure old socket file is removed
    File.rm(socket_path)

    opts = [:binary, active: false, exit_on_close: false, reuseaddr: true]

    case :gen_tcp.listen(0, [{:ifaddr, {:local, socket_path}} | opts]) do
      {:ok, listen_socket} ->
        IO.puts("Daemon listening on UNIX socket #{socket_path}")
        accept_loop(listen_socket)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start daemon: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_socket_path do
    tmp_dir = System.get_env("TMPDIR") || "/tmp/"
    user = System.get_env("USER") || "default"
    Path.join(tmp_dir, "instantgrep_#{user}.sock")
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Task.start(fn -> handle_client(socket) end)
        accept_loop(listen_socket)

      {:error, reason} ->
        IO.puts(:stderr, "Accept failed: #{inspect(reason)}")
        # Continue accepting
        accept_loop(listen_socket)
    end
  end

  defp handle_client(socket) do
    data = receive_all_data(socket, "")
    args = parse_args_from_data(data)

    parsed = Instantgrep.CLI.parse_args(args)

    {_code, msg} =
      case Instantgrep.CLI.execute(parsed) do
        {:ok, output} -> {0, output}
        {:error, c, error_msg} -> {c, error_msg}
      end

    # Send the output back
    if msg != "" do
      :gen_tcp.send(socket, msg)
      # ensure there's a newline if it doesn't have one and we have content
      if not String.ends_with?(msg, "\n"), do: :gen_tcp.send(socket, "\n")
    end

    # We can also send the exit code as a special trailer, but standard grep just outputs.
    # A bash wrapper can't easily distinguish stdout from stderr or extract the exit code 
    # if it's interleaved. For simplicity, we just send output.
    # To transmit exit code, we could dedicate the last byte or line to it, but standard 
    # bash wrapper just exiting 0 or 1 based on if output was produced might be okay,
    # or we can do nothing and just always exit 0 or 1 in wrapper based on string.
    # For now, let's just close the socket, the wrapper will exit 0.

    :gen_tcp.close(socket)
  end

  defp receive_all_data(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        receive_all_data(socket, acc <> data)

      {:error, :closed} ->
        acc
    end
  end

  defp parse_args_from_data(data) do
    data
    |> String.split("\0", trim: true)
  end
end
