# Ledger de revisão de espaçamento e ícones

**Rodada 1 — revisão em execução (27/11/2026).**

Base de inventário: `00e191c43bc7b1aab6b7775a336a176be97fe3c9` (main após #220).
Rotas extraídas pela própria tarefa do Phoenix com módulos já compilados: `Mix.Tasks.Phx.Routes.run(["BeatgridWeb.Router", "--no-compile"], "Beatgrid")` via Elixir, pois `mix phx.routes` falhou com `:eperm`. A declaração de rotas foi também comparada com o router do main remoto. A primeira lista contém 25 rotas HTTP (16 de produto, três páginas de infraestrutura parametrizadas, seis endpoints não visuais). A execução posterior de `mix phx.routes` acrescentou `/live/websocket` (WS) e `/live/longpoll` (GET/POST), totalizando 28 entradas e 27 caminhos distintos. Superfícies foram inventariadas nos templates; a primeira inspeção real deve completar eventuais variantes não descobertas. A revisão anterior em [2026-11-27-ui-density.md](2026-11-27-ui-density.md) é histórico, não evidência desta rodada.

## Como trabalhar pelo ledger

- Uma linha por superfície ou variante relevante. Quando uma linha agrupar estados correlatos, medir **todos** e registrar as evidências individualmente na observação antes de fechar a linha. Acrescentar qualquer superfície descoberta; nunca remover uma linha para aumentar a cobertura.
- Rodada 1 e seguintes: abrir a próxima linha bloqueada recuperável ou pendente, na ordem da tabela. Até duas frentes distintas. Atualize a linha no mesmo PR da mudança.
- Viewports previstos (CSS px): 375×812, 1280×800, 1536×960, 2560×1080; 320px para limites estreitos de avisos/overlays. Use medidas reais de DOM/computed styles, captura visual e navegação conectada. Não confunda estes tamanhos planejados com viewports medidos.
- Checklist: (1) padding; (2) gaps; (3) ritmo vertical; (4) eixos/margens; (5) alinhamento, dimensão e alvo de ícones; (6) texto longo; (7) overflow e respiro na menor largura; (8) vazio, carregamento, erro e lista cheia (quando aplicável). Preservar DESIGN.md e comportamento. Use fixtures isoladas para estados de erro, volume e hardware sem disparar serviços pagos ou mexer no acervo real. Confirmações: inspecionar e cancelar.
- Status: pendente, revisada-com-mudança, revisada-sem-mudança, bloqueada. Ao resolver B1, voltar para pendente. Nada conta como revisado sem renderização; para endpoints sem UI não há oito itens visuais aplicáveis, registrar resposta e consumidor real.
- Repetir a tabela inteira até uma rodada sem mudanças. Conferência final: regenerar rotas, comparar, reabrir todas as linhas no app; qualquer falha volta a pendente. Testes e lint via deck-runner, zero PR aberto, sem deploy.

### Histórico de bloqueios iniciais (resolvidos)

**B1 — servidor e navegador indisponíveis:** `mix phx.server` e `mix phx.routes` falharam com `Mix failed to acquire filesystem lock using TCP, reason: :eperm`; a sondagem de uma porta efêmera em loopback retornou `{:error, :eperm}`. Não há listener em 4003, curl retornou HTTP 000 e Playwright não conseguiu navegar. Desktop Commander estava offline. O checkout sincronizou por outra frente com o main remoto; a edição preexistente de `root.html.heex` foi preservada.

**B2 — Deck:** `deck-runner preflight --repo .` retornou `ready: false`, `code: session_socket_denied`, socket SSH negado e resolução `steamdeck.local` indisponível. Sem recibo de testes/lint desta rodada.

**Retomada 16:05:** Mac via Desktop Commander: TCP OK, Deck preflight ready. Servidor LiveView em 4003 com cópia isolada do banco `beatgrid_ui_spacing_20261127`, biblioteca clonada, Oban sem filas/plugins e integrações pagas desativadas. B1/B2 resolvidos; linhas anteriormente bloqueadas passam a pendentes até ter prova renderizada. Os bloqueios específicos de dados/fixtures são anotados por linha.

## Superfícies

| Página / superfície | Rota | Status | Rodada | PR | Viewports medidos | Observação |
|---|---|---|---|---|---|---|
| Compartilhado — Menu lateral expandido | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Menu lateral recolhido | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Menu mobile fechado | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Menu mobile aberto e foco após Escape | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Flash de sucesso | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Flash de erro | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Reconexão LiveView — cliente e servidor | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Player oculto | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Player ativo — título longo, transporte e volume | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Player — carregando/erro de áudio | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Player — lista de marcadores vazia | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Compartilhado — Player — lista cheia e edição de marcadores | `Todas as rotas de produto` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Lista cheia e paginação | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Lista vazia — acervo sem faixas | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Busca sem resultados | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Busca com títulos longos, ordenação e caminhos | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Painel de filtros e intervalos | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Roda Camelot — diálogo e compatibilidade | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Menu de pasta | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Menu de faixa | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Seleção em lote e barra de ações | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Seleção em lote com player visível | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Biblioteca — Aviso de movimentação, erro e desfazer | `/` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Identidade — título e artista longos | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Navegação de retorno e âncoras | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Editar faixa e metadados — formulário e erro | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Arquivo no disco — pasta, renomeação e desfazer | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Nota, tags vazias/cheias e anotação | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Marcadores — vazio, lista cheia, edição | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Volume — sem análise, analisado e backup | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Análise BPM/tom — divergência e progresso | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Metadados de origem e perfil de áudio | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Versões — vazias e cheias | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Próxima faixa compatível — vazia e cheia | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Sugestões IA — vazias | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Sugestões IA — carregando | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Sugestões IA — lista cheia e histórico importado | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Recuperação — arquivo indisponível | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Ficha da faixa — Avisos de enriquecimento, erro e confirmação nativa | `/track/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Abas e contadores | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Renomeações — lista cheia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Renomeações — vazia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Classificação — lista cheia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Classificação — vazia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Auditoria — lista cheia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Auditoria — vazia | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Lotes aplicados — painel aberto | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Reavaliação — detalhes e controles | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Seleção em lote e estados pendentes/rejeitados | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Comparação e edição inline | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Revisão de sugestões — Confirmações, processamento, sucesso e erro | `/revisao` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Grupos — lista cheia | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Grupos — vazia | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Varredura em andamento | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Escolha de cópia e caminhos longos | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Confirmação de resolução — cancelar | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Duplicatas — Aviso de erro e desfazer | `/dedup` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Resumo de integridade | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Verificação em andamento e resultado | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Arquivos danificados — lista cheia | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Arquivos danificados — vazia | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Diagnóstico aberto e caminhos longos | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Quarentena — filtros e lista cheia | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Quarentena — vazia/sem resultados | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Recuperação de arquivos — Confirmação de restauração — cancelar; erro | `/resgate` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Indicadores e distribuição por gênero | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Artistas mais presentes | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Andamento BPM | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Décadas | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Painéis sem dados | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — seletor de gênero | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — carregamento | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — lista cheia e variantes | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — vazio | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — histórico importado expandido | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Repertório — Lacunas — erro/aviso | `/painel` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Lista de sets — cheia, nomes longos | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Lista de sets — vazia | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Seletor mobile e painel recolhido | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Nenhum set selecionado | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Proposta de faixa vindo da ficha | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — Modal critérios de montagem | `/set` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Cabeçalho e nome longo | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Renomeação — validação | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Sequência vazia | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Sequência cheia e controles de ordem | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Transições, alertas de loudness e respiros | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Ferramentas do set expandido | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Curva de energia | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Planejamento automático — formulário | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Preencher seção | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Mesa de mixagem — faders, pesos e filtros | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Próximas faixas — vazio/lista cheia | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Busca de faixas — vazio/lista cheia | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Proposta de gravação | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Modal critérios — abrir/fechar | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Montagem de sets — edição — Avisos de planejamento, validação, exportação e confirmação | `/set/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Cabeçalho e seletor de set | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Deck A/B vazios | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Deck A/B carregados — nomes longos | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Deck carregando / erro | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Waveforms e estado de transporte | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Mixer e faders | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Fila de set vazia | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Fila cheia e transições | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Biblioteca — busca, vazio, lista cheia | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Preflight — sem problemas | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Preflight — problemas e lista longa | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Painel transições expandido | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Painel scratch expandido | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Painel diagnóstico/log expandido | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — MIDI — desconectado | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — MIDI — conectado e nome de dispositivo | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Modo Viagem — sem faixa | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Modo Viagem — faixa atual e próxima | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Ensaio — diálogo sem decks | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Ensaio — corte e mistura com decks | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Ensaio — aguardando preparação/erro | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Discotecagem — Passagem armada — confirmar e desarmar (#220) | `/discotecagem` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Fila de tarefas — Filtros e contadores | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Header aligned; select 32px; groups 6px gaps; dropdown DownloadWorker patch and context link rendered. |
| Fila de tarefas — Lista cheia e assunto longo | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | 30 rows in fixture catalog; labels/title/errors wrap; rows 10px vertical padding, 6–16px gaps. 3 action buttons one row at 1280+. |
| Fila de tarefas — Lista vazia/sem resultados | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Initial active/failed filters both empty, visible empty copy and back link; header/filter corrected and rerendered on populated filters. |
| Fila de tarefas — Grupo e fases de processamento | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Active and failed phase chips wrap at 375 without overflow; filtered dropdown rendered. |
| Fila de tarefas — Detalhe de falha expandido | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Long fixture URL and multiline error; 12px horizontal detail inset; corrected accidental leading indentation. |
| Fila de tarefas — Tarefa ativa/espera e progresso | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Scheduled, executing, retryable fixture jobs; attempt/time/status and actions clear; no actual task execution. |
| Fila de tarefas — Confirmação nativa de cancelar/repetir/limpar | `/jobs` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Cancel, retry all and clear all dialogs all opened/dismissed at four widths. |
| Manutenção — Navegação e escopo de operações | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Header/container aligned; page anchor links 8px gaps, wrap at mobile, scope visible. |
| Manutenção — Preparação de áudio — BPM, tom e marcadores | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Real complete and partial coverage, 6px high progress bars, controls wrap and align. |
| Manutenção — Normalização — LUFS e ganho | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Real complete/partial measurements and gain count; semantic color preserved. |
| Manutenção — Ganho — backup e desfazer | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Both apply/restore confirmation opened and canceled; scope text wraps/backup described. |
| Manutenção — Enriquecimento — Soundcharts e faixas raras | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Disabled Soundcharts gate/no credentials; queued rare enrichment in isolated queue-disabled copy, no provider run; explanatory copy and button align. |
| Manutenção — Importações YouTube | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Real pending count, link to imports, configured gate and disabled button; 16px card desktop padding and 12px mobile inset. |
| Manutenção — Backup de curadoria — dados e instruções abertas | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual copy backup metadata and open disclosure with long restore command wrapping; no execution. |
| Manutenção — Cobertura vazia e completa | `/manutencao` | bloqueada | 1 | — | parcial: 375/1280/1536/2560 | Complete and partial measured four widths; zero total cannot be asserted until no-tracks isolated fixture DB. Parent to render this in empty DB pass. |
| Manutenção — Progresso de tarefas, bloqueio de integração/erro | `/manutencao` | bloqueada | 1 | — | parcial: 375/1280/1536/2560 | Queue progress/status and disabled integration observed four widths. Need nonzero in-flight progress and terminal error controlled fixture; no actual jobs/providers allowed while app isolated. |
| Manutenção — Confirmações nativas — cancelar | `/manutencao` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Remap, apply gain, restore gain backup dialogs canceled four widths; no destructive action. |
| Ajustes — Sets e discotecagem — 3 preferências | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | 3 rows, labels/values/units aligned; mobile wraps; header corrected. |
| Ajustes — Áudio e backup — 3 preferências | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | 3 rows, 36px inputs, disabled/default states not conflated; header and toast corrected. |
| Ajustes — Curadoria — 2 preferências | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | 2 rows, consistent form/grid and typography; header corrected. |
| Ajustes — Valor padrão/personalizado, reset | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual submit a temporary valid value, verify personalized & success, reset default, restore original override, all isolated. |
| Ajustes — Validação e retorno de sucesso/erro | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Invalid server-side submission exercised by disabling native constraint only in browser test; actual error, valid success and reset feedback rendered; close target measured 32×32. |
| Ajustes — Origem volume — foco e retorno | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual focus `ajuste-value-target_lufs`, return navigates `#maintenance-gain` all widths; header fixed. |
| Ajustes — Origem backup — foco e retorno | `/ajustes` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual focus `ajuste-value-backup_keep`, return navigates `#maintenance-backup` all widths; header fixed. |
| Gêneros — Grade cheia — descrições longas | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Real 7 seeded folders + long-name/description fixture. Dot fixed: 12px at center of first 19.5px line, 8px gap to heading. |
| Gêneros — Grade sem gêneros customizados | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Initial DB exactly seven seed folders, all in use; no custom folder set; complete grid rendered four widths. (If this row means zero folders total rather than seed-only, parent should check empty isolated DB.) |
| Gêneros — Formulário de criação — aberto | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual opened form and focused name, padding16 gap12; color + buttons wrap/read on 375; underlying dot alignment fixed. |
| Gêneros — Formulário de criação — inválido | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Duplicate seeded genre actual validation error rendered, input retained on all widths, no overflow. |
| Gêneros — Editor de descrição — aberto | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual edit/cancel and custom description textarea long value across widths; dot alignment preserved. |
| Gêneros — Sugestão IA — carregando e resultado | `/generos` | bloqueada | 1 | — | parcial: 375/1280/1536/2560 | Requires controlled provider stub and delay to render actual loading/result. Claude CLI not invoked. |
| Gêneros — Erro de edição e confirmação de exclusão | `/generos` | revisada-com-mudança | 1 | Sistema (PR a abrir) | 375×812; 1280×800; 1536×960; 2560×1080 | Actual stale-edit error after removing **only created temporary genre fixture** from isolated DB, all widths; delete dialog on long-name fixture opened/dismissed. |
| Importações — Abas de origem | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Origem online — campos de links e fonte recolhida | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Spotify — catálogo/seletor e filtro | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Spotify — sem resultados | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Prévia de links — carregando/erro | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Prévia de versões — seleção e lista longa | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Recomendação — buscar versão | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Fila online — progresso, falha e recibo | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — YouTube — lista cheia, playlists, filtros e ordenação | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — YouTube — lista vazia | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações — Confirmar exclusão — cancelar | `/importados` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Formulário de pasta/arquivo | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Navegador de diretórios — lista cheia | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Navegador de diretórios — vazio/erro | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Prévia — carregamento/erro | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Prévia — linhas novas e duplicadas | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Prévia — vazia e todos duplicados | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Atividade de importação — progresso e resultado | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Importações locais — Recibo de lote e erro | `/importados?origem=local` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Sets gravados — Importar URL e controle de busca | `/sets-online` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Sets gravados — Lista cheia, título longo e indicadores | `/sets-online` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Sets gravados — Lista vazia/sem resultados | `/sets-online` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Sets gravados — Download/análise em andamento | `/sets-online` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Sets gravados — Falha de importação e aviso | `/sets-online` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Identidade e descrição longa | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Linha do tempo e transporte | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Áudio apagado/indisponível | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Análise em andamento e erro | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Painel de análise e arquivo expandido | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Divisão por DJ — formulário e divisórias | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Faixas — lista cheia | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Faixas — sem segmentos | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Reconhecimento — status e integração sem credenciais | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Novo recorte — painel e contexto | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Novo recorte — modo exato e seleção de intervalo | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Novo recorte — prévia, nome/destino e validação | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Recorte concluído — aviso | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Detalhe do set gravado — Confirmações nativas — cancelar | `/sets-online/:id` | pendente | 1 | — | — | Aguardando inspeção dos estados desta rodada. |
| Infraestrutura Phoenix — Página inicial e navegação | `/dev/dashboard` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — os_mon | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — memory_allocators | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — metrics | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — request_logger | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — applications | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — processes | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — ports | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — sockets | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — ets | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — ecto_stats | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — Detalhe de item — modal onde disponível | `/dev/dashboard/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Infraestrutura Phoenix — Variante por nó e menus | `/dev/dashboard/:node/:page` | pendente | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. |
| Endpoint sem UI — JavaScript de desregistro | `/sw.js` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Endpoint sem UI — Entrega de áudio original | `/audio/:id/original` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Endpoint sem UI — Entrega de áudio | `/audio/:id` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Endpoint sem UI — Entrega de áudio da gravação | `/sets-online/:id/audio` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Endpoint sem UI — CSS de infraestrutura | `/dev/dashboard/css-:md5` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Endpoint sem UI — JavaScript de infraestrutura | `/dev/dashboard/js-:md5` | pendente | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. |
| Transporte LiveView — WebSocket | `/live/websocket` | pendente | 1 | — | — | Verificar socket conectado no navegador. |
| Transporte LiveView — Longpoll GET/POST | `/live/longpoll` | pendente | 1 | — | — | Verificar transporte fallback real. |

## Contagem (atualizar após cada PR)

- Inventário: 209 linhas. 28 revisadas-com-mudança; 3 bloqueadas por estado específico; 178 pendentes; 0 revisadas-sem-mudança.
- Próxima linha: verificar menu lateral expandido e avançar pelos estados restantes.
