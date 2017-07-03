defmodule Nerves.Firmware.SSH.Handler do
  require Logger

  alias Nerves.Firmware.SSH.Command
  alias Nerves.Firmware.SSH.Fwup

  defmodule State do
    defstruct state: :parse_commands,
      id: nil,
      cm: nil,
      commands: [],
      buffer: <<>>,
      bytes_processed: 0,
      fwup: nil
  end

  # See http://erlang.org/doc/man/ssh_channel.html for API

  def init([]) do
    {:ok, %State{}}
  end

  def handle_msg({:ssh_channel_up, channel_id, connection_manager}, state) do
    Logger.debug("new ssh connection")
    {:ok, %{state | id: channel_id, cm: connection_manager}}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:data, _channel_id, 0, data}}, state) do
    process_message(state.state, data, state)
  end
  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, 1, _data}}, state) do
    # Ignore stderr
    {:ok, state}
  end
  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel_id}}, state) do
    {:ok, state}
  end
  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _, _}}, state) do
    # Ignore signals
    {:ok, state}
  end
  def handle_ssh_msg({:ssh_cm, _cm, {:exit_signal, channel_id, _, _error, _}}, state) do
    {:stop, channel_id, state}
  end
  def handle_ssh_msg({:ssh_cm, _cm, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_cast({:fwup_data, response}, state) do
    :ok = :ssh_connection.send(state.cm, state.id, response)
    {:noreply, state}
  end
  def handle_cast({:fwup_exit, 0}, state) do
    buffer = state.buffer
    state = %{state | buffer: <<>>}
    case run_commands(state.commands, buffer, state) do
      {:ok, state} -> {:noreply, state}
      {:stop, _, state} -> {:stop, :normal, state}
    end
  end
  def handle_cast({:fwup_exit, _}, state) do
    {:stop, :fwup_error, state}
  end

  def terminate(_reason, _state) do
    Logger.debug("ssh connection terminated")
    :ok
  end

  defp process_message(:parse_commands, data, state) do
    alldata = state.buffer <> data
    case Command.parse(data) do
      {:error, :partial} ->
        {:ok, %{state | buffer: alldata}}
      {:error, reason} ->
        :ssh_connection.send(state.cm, state.id,
          "nerves_firmware_ssh: error #{reason}\n")
        :ssh_connection.send_eof(state.cm, state.id)
        {:stop, state.id, state}
      {:ok, command_list, rest} ->
        new_state = %{state | buffer: <<>>, state: :running_commands, commands: command_list}
        run_commands(command_list, rest, new_state)
    end
  end
  defp process_message(:running_commands, data, state) do
    alldata = state.buffer <> data
    new_state = %{state | buffer: <<>>}
    run_commands(state.commands, alldata, new_state)
  end
  defp process_message(:wait_for_fwup, data, state) do
    alldata = state.buffer <> data
    new_state = %{state | buffer: alldata}
    {:ok, new_state}
  end

  defp run_commands([], _data, state) do
    :ssh_connection.send_eof(state.cm, state.id)
    {:stop, state.id, state}
  end
  defp run_commands([{:fwup, count} | rest], data, state) do
    state = maybe_fwup(state)

    bytes_left = count - state.bytes_processed
    bytes_to_process = min(bytes_left, byte_size(data))
    <<for_fwup::binary-size(bytes_to_process), leftover::binary>> = data
    :ok = Fwup.send_chunk(state.fwup, for_fwup)

    new_bytes_processed = state.bytes_processed + bytes_to_process
    if new_bytes_processed == count do
      new_state = %{state |
                    state: :wait_for_fwup,
                    buffer: leftover,
                    commands: rest,
                    bytes_processed: 0}
      {:ok, new_state}
    else
      new_state = %{state | bytes_processed: new_bytes_processed}
      {:ok, new_state}
    end
  end
  defp run_commands([:reboot | rest], data, state) do
    Logger.debug("Running reboot command")
    new_state = %{state | commands: rest}
    run_commands(rest, data, new_state)
  end

  defp maybe_fwup(%{fwup: fwup} = state) when fwup == nil do
    {:ok, new_fwup} = Fwup.start_link(self())
    %{state | fwup: new_fwup}
  end
  defp maybe_fwup(state), do: state
end
