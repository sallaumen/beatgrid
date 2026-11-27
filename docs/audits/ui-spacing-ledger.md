# Ledger de revisão de espaçamento e ícones

**Rodada 1 — inventário inicial, revisão visual ainda não executada (27/11/2026).**

Base de inventário: `00e191c43bc7b1aab6b7775a336a176be97fe3c9` (main após #220).
Rotas extraídas pela própria tarefa do Phoenix com módulos já compilados: `Mix.Tasks.Phx.Routes.run(["BeatgridWeb.Router", "--no-compile"], "Beatgrid")` via Elixir, pois `mix phx.routes` falhou com `:eperm`. A declaração de rotas foi também comparada com o router do main remoto. A lista contém 25 rotas HTTP (16 de produto, três páginas de infraestrutura parametrizadas, seis endpoints não visuais). Superfícies foram inventariadas nos templates; a primeira inspeção real deve completar eventuais variantes não descobertas. A revisão anterior em [2026-11-27-ui-density.md](2026-11-27-ui-density.md) é histórico, não evidência desta rodada.

## Como trabalhar pelo ledger

- Uma linha por superfície ou variante relevante. Quando uma linha agrupar estados correlatos, medir **todos** e registrar as evidências individualmente na observação antes de fechar a linha. Acrescentar qualquer superfície descoberta; nunca remover uma linha para aumentar a cobertura.
- Rodada 1 e seguintes: abrir a próxima linha bloqueada recuperável ou pendente, na ordem da tabela. Até duas frentes distintas. Atualize a linha no mesmo PR da mudança.
- Viewports previstos (CSS px): 375×812, 1280×800, 1536×960, 2560×1080; 320px para limites estreitos de avisos/overlays. Use medidas reais de DOM/computed styles, captura visual e navegação conectada. Não confunda estes tamanhos planejados com viewports medidos.
- Checklist: (1) padding; (2) gaps; (3) ritmo vertical; (4) eixos/margens; (5) alinhamento, dimensão e alvo de ícones; (6) texto longo; (7) overflow e respiro na menor largura; (8) vazio, carregamento, erro e lista cheia (quando aplicável). Preservar DESIGN.md e comportamento. Use fixtures isoladas para estados de erro, volume e hardware sem disparar serviços pagos ou mexer no acervo real. Confirmações: inspecionar e cancelar.
- Status: pendente, revisada-com-mudança, revisada-sem-mudança, bloqueada. Ao resolver B1, voltar para pendente. Nada conta como revisado sem renderização; para endpoints sem UI não há oito itens visuais aplicáveis, registrar resposta e consumidor real.
- Repetir a tabela inteira até uma rodada sem mudanças. Conferência final: regenerar rotas, comparar, reabrir todas as linhas no app; qualquer falha volta a pendente. Testes e lint via deck-runner, zero PR aberto, sem deploy.

### Bloqueios atuais

**B1 — servidor e navegador indisponíveis:** `mix phx.server` e `mix phx.routes` falharam com `Mix failed to acquire filesystem lock using TCP, reason: :eperm`; a sondagem de uma porta efêmera em loopback retornou `{:error, :eperm}`. Não há listener em 4003, curl retornou HTTP 000 e Playwright não conseguiu navegar. Desktop Commander estava offline. O checkout sincronizou por outra frente com o main remoto; a edição preexistente de `root.html.heex` foi preservada.

**B2 — Deck:** `deck-runner preflight --repo .` retornou `ready: false`, `code: session_socket_denied`, socket SSH negado e resolução `steamdeck.local` indisponível. Sem recibo de testes/lint desta rodada.

## Superfícies

| Página / superfície | Rota | Status | Rodada | PR | Viewports medidos | Observação |
|---|---|---|---|---|---|---|
| Compartilhado — Menu lateral expandido | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Menu lateral recolhido | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Menu mobile fechado | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Menu mobile aberto e foco após Escape | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Flash de sucesso | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Flash de erro | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Reconexão LiveView — cliente e servidor | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Player oculto | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Player ativo — título longo, transporte e volume | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Player — carregando/erro de áudio | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Player — lista de marcadores vazia | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Compartilhado — Player — lista cheia e edição de marcadores | `Todas as rotas de produto` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Lista cheia e paginação | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Lista vazia — acervo sem faixas | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Busca sem resultados | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Busca com títulos longos, ordenação e caminhos | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Painel de filtros e intervalos | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Roda Camelot — diálogo e compatibilidade | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Menu de pasta | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Menu de faixa | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Seleção em lote e barra de ações | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Seleção em lote com player visível | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Biblioteca — Aviso de movimentação, erro e desfazer | `/` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Identidade — título e artista longos | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Navegação de retorno e âncoras | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Editar faixa e metadados — formulário e erro | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Arquivo no disco — pasta, renomeação e desfazer | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Nota, tags vazias/cheias e anotação | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Marcadores — vazio, lista cheia, edição | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Volume — sem análise, analisado e backup | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Análise BPM/tom — divergência e progresso | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Metadados de origem e perfil de áudio | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Versões — vazias e cheias | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Próxima faixa compatível — vazia e cheia | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Sugestões IA — vazias | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Sugestões IA — carregando | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Sugestões IA — lista cheia e histórico importado | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Recuperação — arquivo indisponível | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ficha da faixa — Avisos de enriquecimento, erro e confirmação nativa | `/track/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Abas e contadores | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Renomeações — lista cheia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Renomeações — vazia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Classificação — lista cheia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Classificação — vazia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Auditoria — lista cheia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Auditoria — vazia | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Lotes aplicados — painel aberto | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Reavaliação — detalhes e controles | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Seleção em lote e estados pendentes/rejeitados | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Comparação e edição inline | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Revisão de sugestões — Confirmações, processamento, sucesso e erro | `/revisao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Grupos — lista cheia | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Grupos — vazia | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Varredura em andamento | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Escolha de cópia e caminhos longos | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Confirmação de resolução — cancelar | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Duplicatas — Aviso de erro e desfazer | `/dedup` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Resumo de integridade | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Verificação em andamento e resultado | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Arquivos danificados — lista cheia | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Arquivos danificados — vazia | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Diagnóstico aberto e caminhos longos | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Quarentena — filtros e lista cheia | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Quarentena — vazia/sem resultados | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Recuperação de arquivos — Confirmação de restauração — cancelar; erro | `/resgate` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Indicadores e distribuição por gênero | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Artistas mais presentes | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Andamento BPM | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Décadas | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Painéis sem dados | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — seletor de gênero | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — carregamento | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — lista cheia e variantes | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — vazio | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — histórico importado expandido | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Repertório — Lacunas — erro/aviso | `/painel` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Lista de sets — cheia, nomes longos | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Lista de sets — vazia | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Seletor mobile e painel recolhido | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Nenhum set selecionado | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Proposta de faixa vindo da ficha | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — Modal critérios de montagem | `/set` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Cabeçalho e nome longo | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Renomeação — validação | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Sequência vazia | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Sequência cheia e controles de ordem | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Transições, alertas de loudness e respiros | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Ferramentas do set expandido | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Curva de energia | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Planejamento automático — formulário | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Preencher seção | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Mesa de mixagem — faders, pesos e filtros | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Próximas faixas — vazio/lista cheia | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Busca de faixas — vazio/lista cheia | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Proposta de gravação | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Modal critérios — abrir/fechar | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Montagem de sets — edição — Avisos de planejamento, validação, exportação e confirmação | `/set/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Cabeçalho e seletor de set | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Deck A/B vazios | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Deck A/B carregados — nomes longos | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Deck carregando / erro | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Waveforms e estado de transporte | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Mixer e faders | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Fila de set vazia | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Fila cheia e transições | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Biblioteca — busca, vazio, lista cheia | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Preflight — sem problemas | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Preflight — problemas e lista longa | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Painel transições expandido | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Painel scratch expandido | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Painel diagnóstico/log expandido | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — MIDI — desconectado | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — MIDI — conectado e nome de dispositivo | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Modo Viagem — sem faixa | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Modo Viagem — faixa atual e próxima | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Ensaio — diálogo sem decks | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Ensaio — corte e mistura com decks | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Ensaio — aguardando preparação/erro | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Discotecagem — Passagem armada — confirmar e desarmar (#220) | `/discotecagem` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Filtros e contadores | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Lista cheia e assunto longo | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Lista vazia/sem resultados | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Grupo e fases de processamento | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Detalhe de falha expandido | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Tarefa ativa/espera e progresso | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Fila de tarefas — Confirmação nativa de cancelar/repetir/limpar | `/jobs` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Navegação e escopo de operações | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Preparação de áudio — BPM, tom e marcadores | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Normalização — LUFS e ganho | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Ganho — backup e desfazer | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Enriquecimento — Soundcharts e faixas raras | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Importações YouTube | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Backup de curadoria — dados e instruções abertas | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Cobertura vazia e completa | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Progresso de tarefas, bloqueio de integração/erro | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Manutenção — Confirmações nativas — cancelar | `/manutencao` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Sets e discotecagem — 3 preferências | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Áudio e backup — 3 preferências | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Curadoria — 2 preferências | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Valor padrão/personalizado, reset | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Validação e retorno de sucesso/erro | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Origem volume — foco e retorno | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Ajustes — Origem backup — foco e retorno | `/ajustes` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Grade cheia — descrições longas | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Grade sem gêneros customizados | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Formulário de criação — aberto | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Formulário de criação — inválido | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Editor de descrição — aberto | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Sugestão IA — carregando e resultado | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Gêneros — Erro de edição e confirmação de exclusão | `/generos` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Abas de origem | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Origem online — campos de links e fonte recolhida | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Spotify — catálogo/seletor e filtro | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Spotify — sem resultados | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Prévia de links — carregando/erro | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Prévia de versões — seleção e lista longa | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Recomendação — buscar versão | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Fila online — progresso, falha e recibo | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — YouTube — lista cheia, playlists, filtros e ordenação | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — YouTube — lista vazia | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações — Confirmar exclusão — cancelar | `/importados` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Formulário de pasta/arquivo | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Navegador de diretórios — lista cheia | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Navegador de diretórios — vazio/erro | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Prévia — carregamento/erro | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Prévia — linhas novas e duplicadas | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Prévia — vazia e todos duplicados | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Atividade de importação — progresso e resultado | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Importações locais — Recibo de lote e erro | `/importados?origem=local` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Sets gravados — Importar URL e controle de busca | `/sets-online` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Sets gravados — Lista cheia, título longo e indicadores | `/sets-online` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Sets gravados — Lista vazia/sem resultados | `/sets-online` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Sets gravados — Download/análise em andamento | `/sets-online` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Sets gravados — Falha de importação e aviso | `/sets-online` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Identidade e descrição longa | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Linha do tempo e transporte | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Áudio apagado/indisponível | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Análise em andamento e erro | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Painel de análise e arquivo expandido | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Divisão por DJ — formulário e divisórias | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Faixas — lista cheia | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Faixas — sem segmentos | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Reconhecimento — status e integração sem credenciais | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Novo recorte — painel e contexto | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Novo recorte — modo exato e seleção de intervalo | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Novo recorte — prévia, nome/destino e validação | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Recorte concluído — aviso | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Detalhe do set gravado — Confirmações nativas — cancelar | `/sets-online/:id` | bloqueada | 1 | — | — | B1 — ainda sem medição nesta rodada. |
| Infraestrutura Phoenix — Página inicial e navegação | `/dev/dashboard` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — os_mon | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — memory_allocators | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — metrics | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — request_logger | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — applications | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — processes | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — ports | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — sockets | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — ets | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — ecto_stats | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — Detalhe de item — modal onde disponível | `/dev/dashboard/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Infraestrutura Phoenix — Variante por nó e menus | `/dev/dashboard/:node/:page` | bloqueada | 1 | — | — | Infraestrutura externa ao design A Cabine; confirmar disponibilidade no runtime. B1. |
| Endpoint sem UI — JavaScript de desregistro | `/sw.js` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |
| Endpoint sem UI — Entrega de áudio original | `/audio/:id/original` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |
| Endpoint sem UI — Entrega de áudio | `/audio/:id` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |
| Endpoint sem UI — Entrega de áudio da gravação | `/sets-online/:id/audio` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |
| Endpoint sem UI — CSS de infraestrutura | `/dev/dashboard/css-:md5` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |
| Endpoint sem UI — JavaScript de infraestrutura | `/dev/dashboard/js-:md5` | bloqueada | 1 | — | — | Sem superfície visual; verificar resposta/consumidor na conferência final. B1. |

## Contagem inicial

- 207 linhas: 207 bloqueadas, 0 pendentes, 0 revisadas-com-mudança, 0 revisadas-sem-mudança.
- 0 linhas verificadas no navegador nesta rodada. Não é entrega concluída.
- Próxima linha: menu lateral expandido (B1), seguido das demais, sem pular estados.
