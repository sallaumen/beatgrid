# Revisão de composição da Cabine — 27/11/2026

Escopo: todas as rotas de produto de `BeatgridWeb.Router`, incluindo os estados e controles internos; sem mudança de domínio, dados, preferências, dependências ou deploy. A referência permanece `DESIGN.md` (A Cabine). Base: `c15e8d27e7abaef653edc48dbd10f97404e84eca`.

## Cobertura

A coordenação preservou o arquivo `components/layouts/root.html.heex`, que já continha alterações locais independentes. As frentes tiveram propriedade exclusiva dos templates; CSS compartilhado, avisos e integração ficaram com a coordenação.

| Rota / superfície | Responsável | Revisão de composição e estados | Evidência |
|---|---|---|---|
| `/` Biblioteca | Biblioteca | Filtros, busca/caminhos, seleção em lote, roda harmônica, menus de pasta/faixa, ausência de resultados, player | Navegador |
| `/track/:id` Ficha | Biblioteca | Título/artista, âncoras, detalhes, edição/cancelamento, volume, marcadores, análise e versões | Navegador |
| `/importados` Importações | Curadoria | Origem/abas, filtro, ordenação, playlists, importação local (sem iniciar importação) | Navegador |
| `/painel` Repertório | Curadoria | Indicadores, distribuição, artistas, BPM, décadas, lacunas por gênero | Navegador |
| `/revisao` Revisão | Curadoria | Abas renomes, classificações e auditoria; comparação, edição/cancelamento e filtros | Navegador |
| `/dedup` Duplicatas | Curadoria | Agrupamento, escolhas, avisos, estado vazio | Navegador (sem grupos pendentes) |
| `/generos` Gêneros | Curadoria | Cartões, descrição longa, formulário novo/editar/cancelar | Navegador |
| `/resgate` Recuperação | Curadoria | Integridade, atalhos, filtro, lista/estado vazio | Navegador |
| `/set`, `/set/:id` Montagem | Sets | Seletor, sequência, critérios, planejamento, preenchimento, faders, busca, candidatos e proposta | Navegador |
| `/discotecagem` Cabine | Cabine | Decks, mixer, fila, biblioteca, transições, scratch, MIDI, checagem e modo viagem (Escape) | Navegador; decks pausados |
| `/sets-online` Sets gravados | Sets | Lista, busca, ausência de resultados, indicadores | Navegador |
| `/sets-online/:id` Gravação | Sets | Linha do tempo, análise, divisão, faixas, formulário e prévia de recorte | Navegador |
| `/jobs` Fila | Sistema | Filtros, itens, estado vazio, disposição de erro | Navegador (sem tarefas falhas na base) |
| `/manutencao` Manutenção | Sistema | Âncoras, escopo, ações, detalhes de backup e retorno | Navegador; sem executar operações |
| `/ajustes` Ajustes | Sistema | Três grupos, oito preferências, alinhamento de controles, foco/retorno | Navegador; sem gravar preferências |
| Menu, avisos e player global | Coordenação | Menu desktop e mobile, Escape e foco, limites do aviso e controles do player | Navegador |
| `/dev/dashboard` | Coordenação | Rota de infraestrutura Phoenix LiveDashboard, fora do design de produto | Verificação da rota |

## Medidas verificadas

- Biblioteca: a 1400 px, linha em seleção passou de 910 px de largura rolável (904 disponíveis) para 904 px; última ação dentro da linha e título com 212 px.
- Biblioteca no ultrawide: largura da tabela de 2064 para 1560 px; campo de busca de 1933 para 768 px. Em 375 × 812 com player ativo, a barra de seleção termina em y=700 e o player começa em y=711, sem sobreposição.
- Notificação: a 320 px, a área fixa passou de x=-16 e 320 px de largura para x=16 e 288 px.
- Repertório: painel BPM de 793 para 437 px de altura; lacunas visíveis a 1536 × 960.
- Gêneros: largura máxima dos cartões de 770 para 509 px em ultrawide, rodapés alinhados.
- Montagem: intervalo de controles entre faixas de 125 para 80 px a 375, 101 para 56 px a 1280 e 45 para 28 px a 1536/2560; controles mantêm 24 px.
- Cabine: controles A/B no mesmo eixo Y, filas equilibradas (399/399 px a 1280, 667/667 px a 2560) e botões de Viagem com 64 px.
- Sistema: filtros de tarefas com mesma altura; espaço título → ação em Manutenção de 20 para 12 px; posição de Salvar consistente nos oito ajustes.

## Validação e limites

A revisão de código e o detector de layout foram complementados por capturas reais de Chromium em 375, 1280, 1536 e 2560 px (também 320, 768, 1024 e 1400 em superfícies específicas). Sem alterar arquivos de áudio ou disparar chamadas pagas. A reprodução global foi exercitada com uma faixa local, incluindo avanço, pausa por teclado, navegação, marcadores e fechamento. A cabine foi conferida com os decks pausados; transições de áudio ao vivo e operações que alteram o acervo não foram executadas nesta revisão visual.

Os estados dependentes de dados não existentes nesta biblioteca (grupo pendente de duplicatas, tarefa falha, alguns estados de carregamento/erro) foram revisados no código e mantiveram seus testes existentes. Não foram criados registros artificiais no banco de desenvolvimento. Evidências locais de execução em `/tmp/beatgrid-{library,curation,sets,booth}-visual/`, `/tmp/beatgrid-ui-system-audit/` e `/tmp/beatgrid-shared-review*.json`.

Lint de base completo: aprovado (Dialyzer, 0 erros; avisos de compilação existentes nos templates reavaliados). O detector é uma verificação adicional, não substitui as medidas do navegador.
