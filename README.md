# Beatgrid

[![CI](https://github.com/sallaumen/beatgrid/actions/workflows/ci.yml/badge.svg)](https://github.com/sallaumen/beatgrid/actions/workflows/ci.yml)
[![Licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-4e2a8e.svg)](https://elixir-lang.org)

**[English version](README.en.md)**

Gerenciador de biblioteca para DJ, feito em Elixir + Phoenix LiveView. Nasceu
para organizar uma coleção de forró e MPB: escaneia os arquivos de música do
disco, remove duplicatas, organiza em pastas por gênero, enriquece com
metadados (BPM, tom, energia), monta sets com arco de energia e transições, e
toca tudo num player com crossfade.

O **sistema de arquivos é a fonte da verdade**: mover uma faixa no app move o
arquivo no disco (com desfazer). O banco é só uma camada de conhecimento sobre
os arquivos — a música nunca vive neste repositório.

## Onde fazer cada tarefa

| Área do menu | Página | O que você faz ali |
| --- | --- | --- |
| Coleção | Biblioteca | Buscar e ouvir faixas, filtrar por BPM ou tom e organizar várias de uma vez. Abra uma faixa para editar seus dados, notas, marcadores e Selo Ouro. |
| Coleção | Importações | Em **YouTube e Spotify**, conferir versões, selecionar vídeos e acompanhar o lote. Em **Pasta ou arquivo**, revisar os arquivos locais e confirmar a cópia. |
| Coleção | Repertório | Ver a distribuição da coleção e buscar sugestões por pasta. Uma sugestão escolhida abre a conferência em Importações. |
| Curadoria | Revisão de sugestões | Aprovar, corrigir ou rejeitar propostas de nome e classificação. Consultar e desfazer lotes aplicados. |
| Curadoria | Duplicatas · Gêneros · Recuperação de arquivos | Comparar cópias em Duplicatas, administrar as pastas de gênero em Gêneros e recuperar áudio danificado ou em quarentena em Recuperação de arquivos. |
| Sets e palco | Montagem de sets | Montar e reordenar a sequência, ajustar o planejamento, ouvir o set e exportar M3U. **Abrir na discotecagem** leva o set selecionado para os decks. |
| Sets e palco | Sets gravados | Estudar uma gravação longa, identificar trechos e abrir a faixa criada por um recorte. O reconhecimento pago com AudD pede confirmação. |
| Sets e palco | Discotecagem | Tocar ao vivo nos dois decks com vinil, scratch, efeitos, transições, fones e controladora MIDI. |
| Sistema | Fila de tarefas | Filtrar downloads, importações e análises por tipo e estado, inspecionar erros e repetir uma tentativa. |
| Sistema | Manutenção | Analisar a biblioteca, medir volume, aplicar ou desfazer ganho em lote, preparar marcadores, enriquecer metadados e gerar backups da curadoria. |
| Sistema | Ajustes | Alterar preferências de sets, discotecagem, áudio, backup e curadoria. |

## O que ele faz

- **Organiza de verdade**: dedup por conteúdo, pastas por gênero, quarentena
  reversível — nunca deleta um arquivo.
- **Metadados por todos os lados**: tags ID3 (ffprobe), API do Soundcharts
  (BPM/tom/energia), análise local com librosa (independente de API) e
  classificação de gênero por IA — tudo vira sugestão revisável antes de tocar
  no disco.
- **Sets dignos de DJ**: planejador com arco de energia (abertura → picos e
  respiros → queda), faixas raras nos auges, transições automáticas
  (corte/fade/crossfade) baseadas em marcadores de entrada/saída detectados por
  análise de áudio, e player com crossfade de dois decks.
- **Volume padronizado**: mede loudness (LUFS) e aplica ganho nos arquivos
  (mp3gain sem perda para MP3; ffmpeg para o resto), com desfazer.
- **Importações** permite conferir os títulos e selecionar as faixas antes de baixar.
  Um link de vídeo com rádio abre só o vídeo. Para escolher músicas de uma playlist,
  cole o link da própria lista. A fila mostra o estado de cada download e permite tentar de novo.
- **Playlists públicas do Spotify** servem de repertório. A tela lê as faixas da prévia
  pública, indica coincidências de artista e título na biblioteca e busca versões no YouTube.
  O DJ escolhe o vídeo antes de baixar. A disponibilidade do áudio depende do YouTube.
- Toda mudança de disco passa por **propor → revisar → aplicar → desfazer**,
  registrada num log de operações.

## Como rodar

### Requisitos

Só os três primeiros são obrigatórios; o resto libera funcionalidades
individuais (o app roda sem eles, e a suíte de testes não precisa de nenhum —
tudo é mockado).

| Ferramenta | Para quê |
| --- | --- |
| Elixir 1.19 / OTP 27 | o app |
| Docker | PostgreSQL de dev e teste (porta 5434) |
| ffmpeg | leitura de metadados, tags, ganho |
| mp3gain *(opcional)* | ganho sem perda em MP3 |
| yt-dlp *(opcional)* | importação do YouTube |
| Python 3 + librosa *(opcional)* | BPM/tom/marcadores offline |
| claude CLI *(opcional)* | classificação de gênero e sugestões por IA |
| Chave do Soundcharts *(opcional)* | enriquecimento de metadados (`.env`) |

No macOS, o Beatgrid dá preferência ao yt-dlp instalado em
`~/Library/Application Support/beatgrid/yt-dlp/bin/yt-dlp`. Também aceita o executável do sistema.

### macOS

```sh
brew install elixir ffmpeg           # + opcionais: mp3gain yt-dlp
pip install librosa                  # opcional: análise offline
```

### Linux (Debian/Ubuntu)

```sh
# Elixir/OTP: recomendado via asdf (https://asdf-vm.com) ou pacotes da distro
sudo apt install ffmpeg              # + opcionais: mp3gain yt-dlp
pip install librosa                  # opcional: análise offline
```

### Subir o app

```sh
docker compose up -d                 # Postgres (porta 5434)
cp .env.example .env                 # opcional: SOUNDCHARTS_* e LIBRARY_ROOT
mix setup                            # deps + banco + seeds + assets
mix phx.server                       # http://localhost:4000
```

Aponte `LIBRARY_ROOT` no `.env` para a sua pasta de músicas (padrão:
`~/Music/DJ`).

### Testes e qualidade

```sh
mix test     # suíte completa, rápida (ferramentas externas mockadas)
mix lint     # format + credo --strict + sobelow + dialyzer
```

### Elixir Agent Kit

O [Elixir Agent Kit](https://hexdocs.pm/elixir_agent_kit/instalacao.html) é uma dependência Hex de desenvolvimento e testes. Após `mix deps.get`, rode `mix agent_kit.check` para conferir as referências locais. Para atualizar dentro da faixa `~> 1.2`, rode `mix deps.update elixir_agent_kit`, revise `mix agent_kit.sync --dry-run`, aplique com `mix agent_kit.sync` e repita o check.

## Arquitetura em uma nota

Contextos por domínio com módulos de query dedicados; toda integração externa
é um behaviour com adapter real + mock (Mox); jobs pesados rodam em background
(Oban) com progresso ao vivo via PubSub; erros são dados (`{:ok, _}` /
`{:error, _}`); TDD com gate estrito. Detalhes em `docs/playbook/` e
`AGENTS.md`.

## Licença

[MIT](LICENSE) — software livre: use, estude, modifique e distribua à vontade.

---

Um projeto pessoal, feito para a mala de um DJ de forró.
