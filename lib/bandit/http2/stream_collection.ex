defmodule Bandit.HTTP2.StreamCollection do
  @moduledoc """
  Represents a collection of HTTP/2 streams, accessible by stream id or pid.
  Provides the ability to track streams with any identifier, even though it 
  only manages explicit state for existing (current) streams.
  """

  defstruct initial_recv_window_size: 65_535,
            initial_send_window_size: 65_535,
            last_local_stream_id: 0,
            last_remote_stream_id: 0,
            streams: %{}

  require Integer

  alias Bandit.HTTP2.Stream

  @typedoc "A collection of Stream structs, accessisble by id or pid"
  @type t :: %__MODULE__{
          initial_recv_window_size: non_neg_integer(),
          initial_send_window_size: non_neg_integer(),
          last_remote_stream_id: Stream.stream_id(),
          last_local_stream_id: Stream.stream_id(),
          streams: %{Stream.stream_id() => Stream.t()}
        }

  @spec update_initial_send_window_size(t(), non_neg_integer()) :: t()
  def update_initial_send_window_size(collection, initial_send_window_size) do
    delta = initial_send_window_size - collection.initial_send_window_size

    streams =
      collection.streams
      |> Enum.map(fn
        {id, %Stream{state: state} = stream} when state in [:open, :remote_closed] ->
          {id, %{stream | send_window_size: stream.send_window_size + delta}}

        {id, stream} ->
          {id, stream}
      end)
      |> Map.new()

    %{collection | streams: streams, initial_send_window_size: initial_send_window_size}
  end

  @spec get_stream(t(), Stream.stream_id()) :: {:ok, Stream.t()}
  def get_stream(collection, stream_id) do
    case Map.get(collection.streams, stream_id) do
      %Stream{} = stream ->
        {:ok, stream}

      nil ->
        cond do
          Integer.is_even(stream_id) && stream_id <= collection.last_local_stream_id ->
            {:ok,
             %Stream{
               stream_id: stream_id,
               state: :closed,
               recv_window_size: collection.initial_recv_window_size,
               send_window_size: collection.initial_send_window_size
             }}

          Integer.is_odd(stream_id) && stream_id <= collection.last_remote_stream_id ->
            {:ok,
             %Stream{
               stream_id: stream_id,
               state: :closed,
               recv_window_size: collection.initial_recv_window_size,
               send_window_size: collection.initial_send_window_size
             }}

          true ->
            {:ok,
             %Stream{
               stream_id: stream_id,
               state: :idle,
               recv_window_size: collection.initial_recv_window_size,
               send_window_size: collection.initial_send_window_size
             }}
        end
    end
  end

  @spec get_active_stream_by_pid(t(), pid()) :: {:ok, Stream.t()} | {:error, :no_stream}
  def get_active_stream_by_pid(collection, pid) do
    case Enum.find(collection.streams, fn {_stream_id, stream} -> stream.pid == pid end) do
      {_, %Stream{} = stream} -> {:ok, stream}
      nil -> {:error, :no_stream}
    end
  end

  @spec put_stream(t(), Stream.t()) :: {:ok, t()} | {:error, :invalid_stream}
  def put_stream(collection, %Stream{state: state} = stream) when state in [:idle, :closed] do
    case stream.pid do
      nil -> {:ok, %{collection | streams: Map.delete(collection.streams, stream.stream_id)}}
      _pid -> {:error, :invalid_stream}
    end
  end

  def put_stream(collection, %Stream{} = stream) do
    case stream.pid do
      nil ->
        {:error, :invalid_stream}

      _pid ->
        streams = Map.put(collection.streams, stream.stream_id, stream)

        last_local_stream_id =
          if Integer.is_even(stream.stream_id) do
            max(stream.stream_id, collection.last_local_stream_id)
          else
            collection.last_local_stream_id
          end

        last_remote_stream_id =
          if Integer.is_odd(stream.stream_id) do
            max(stream.stream_id, collection.last_remote_stream_id)
          else
            collection.last_remote_stream_id
          end

        {:ok,
         %{
           collection
           | streams: streams,
             last_remote_stream_id: last_remote_stream_id,
             last_local_stream_id: last_local_stream_id
         }}
    end
  end

  @spec next_local_stream_id(t()) :: Stream.stream_id()
  def next_local_stream_id(collection), do: collection.last_local_stream_id + 2

  @spec last_remote_stream_id(t()) :: Stream.stream_id()
  def last_remote_stream_id(collection), do: collection.last_remote_stream_id
end
