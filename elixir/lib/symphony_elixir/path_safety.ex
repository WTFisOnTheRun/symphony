defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    case validate_segment(segment) do
      :ok -> resolve_valid_segment(root, resolved_segments, segment, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_valid_segment(root, resolved_segments, segment, rest) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink_segment(root, resolved_segments, candidate_path, rest)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink_segment(root, resolved_segments, candidate_path, rest) do
    with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
      {target_root, target_segments} = split_absolute_path(resolved_target)
      resolve_segments(target_root, [], target_segments ++ rest)
    end
  end

  defp validate_segment(segment) when byte_size(segment) > 255, do: {:error, :enametoolong}
  defp validate_segment(segment), do: if(String.contains?(segment, <<0>>), do: {:error, :badarg}, else: :ok)

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
