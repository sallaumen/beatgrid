defmodule Beatgrid.Settings.Registry do
  @moduledoc """
  The declarative catalog of runtime tunables — the single source the Ajustes
  panel renders: key, pt-BR copy, numeric type, valid range and the default
  each owning module falls back to.

  The owners' fallbacks are private module attributes, so `RegistryTest` pins
  every `default` here against the owner's effective value with no override
  set — the one guard against the two drifting apart.
  """

  alias Beatgrid.Backup
  alias Beatgrid.Gold
  alias Beatgrid.Library.TrackQuery
  alias Beatgrid.Loudness
  alias Beatgrid.Organization.ClassificationAI
  alias Beatgrid.Sets
  alias Beatgrid.Settings

  @type entry :: %{
          key: atom(),
          label: String.t(),
          description: String.t(),
          type: :integer | :float,
          min: number(),
          max: number() | nil,
          default: number(),
          unit: String.t() | nil,
          effective: (-> number())
        }

  @doc "Every tunable, in display order."
  @spec all() :: [entry()]
  def all do
    [
      %{
        key: :breather_gap_s,
        label: "Respiro: silêncio entre as músicas",
        description:
          "Segundos de silêncio real que o respiro 🤝 deixa entre o fim da música e a próxima — o momento do abraço e da troca de par.",
        type: :float,
        min: 1.0,
        max: 20.0,
        default: 5.0,
        unit: "s",
        effective: &Sets.breather_gap_s/0
      },
      %{
        key: :breather_every,
        label: "Respiro: cadência",
        description:
          "Conectar/Remixar/Planejar marcam um respiro 🤝 a cada N músicas. No editor dá pra mover fronteira a fronteira depois.",
        type: :integer,
        min: 2,
        max: 10,
        default: 4,
        unit: "músicas",
        effective: &Sets.breather_every/0
      },
      %{
        key: :backup_keep,
        label: "Backups do banco guardados",
        description:
          "Quantos dumps diários ficam em _Backups/DB antes da retenção apagar os mais antigos.",
        type: :integer,
        min: 3,
        max: 60,
        default: 14,
        unit: "dumps",
        effective: &Backup.keep/0
      },
      %{
        key: :target_lufs,
        label: "Alvo de loudness",
        description:
          "Loudness alvo da normalização — o “Aplicar ganho” empurra as faixas para este nível.",
        type: :float,
        min: -30.0,
        max: 0.0,
        default: -14.0,
        unit: "LUFS",
        effective: &Loudness.target_lufs/0
      },
      %{
        key: :gain_tolerance_db,
        label: "Tolerância de ganho",
        description:
          "Margem em torno do alvo antes de uma faixa entrar na fila do “Aplicar ganho”.",
        type: :float,
        min: 0.0,
        max: 12.0,
        default: 1.0,
        unit: "dB",
        effective: &Loudness.gain_tolerance_db/0
      },
      %{
        key: :gold_view_threshold,
        label: "Limiar de popularidade (Selo Ouro)",
        description:
          "Views no YouTube a partir das quais uma faixa conta como popular no Selo Ouro.",
        type: :integer,
        min: 0,
        max: nil,
        default: 1_000_000,
        unit: "views",
        effective: &Gold.view_threshold/0
      },
      %{
        key: :instrumental_min,
        label: "Piso do “Menos vozes”",
        description:
          "Instrumentalidade mínima (0–1) pra faixa contar como “mais musical” no filtro do console.",
        type: :float,
        min: 0.0,
        max: 1.0,
        default: 0.1,
        unit: nil,
        effective: &TrackQuery.instrumental_min/0
      },
      %{
        key: :auto_file_confidence,
        label: "Confiança pra auto-arquivar",
        description:
          "Confiança mínima (0–1) da IA pra arquivar uma classificação sozinha, sem passar pela Revisão.",
        type: :float,
        min: 0.0,
        max: 1.0,
        default: 0.80,
        unit: nil,
        effective: &ClassificationAI.auto_file_confidence/0
      }
    ]
  end

  @doc "The entry for a CLIENT-supplied key string — nil for anything unknown (no atom conversion)."
  @spec by_param(String.t()) :: entry() | nil
  def by_param(param) when is_binary(param),
    do: Enum.find(all(), &(Atom.to_string(&1.key) == param))

  @doc "True when an override is stored for the key (the panel's “personalizado” badge)."
  @spec override?(atom()) :: boolean()
  def override?(key), do: Settings.get(key, :__default__) != :__default__

  @doc """
  Parses and validates a user-typed value against the entry's type and range.
  `:error` for unknown keys, wrong types, or out-of-range values.
  """
  @spec parse(atom(), String.t()) :: {:ok, number()} | :error
  def parse(key, raw) when is_atom(key) and is_binary(raw) do
    with %{} = entry <- Enum.find(all(), &(&1.key == key)),
         {:ok, value} <- parse_number(entry.type, String.trim(raw)),
         true <- in_range?(entry, value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp parse_number(:integer, raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_number(:float, raw) do
    case Float.parse(raw) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  defp in_range?(%{min: min, max: max}, value),
    do: value >= min and (is_nil(max) or value <= max)
end
