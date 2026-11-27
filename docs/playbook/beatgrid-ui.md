# Como revisar as telas do Beatgrid

Na preparação, o DJ precisa comparar faixas e prever o efeito de cada escolha. No palco, precisa reconhecer o deck, o estado do áudio e o transporte num relance. A referência visual é [A Cabine](../../DESIGN.md). A tarefa de cada tela está no [mapa da aplicação](../../README.md#onde-fazer-cada-tarefa).

## Qual skill usar

| Pergunta de revisão | Skill | O que observar no Beatgrid |
|---|---|---|
| A informação mais importante aparece primeiro? | Impeccable, com *critique*, *clarify* e *polish* | Comece por uma faixa, set ou tarefa real. Teste se o título, o estado e a ação mais frequente sobrevivem a uma janela estreita. |
| O que tornou essa tela genérica ou ruidosa? | Playbook Unslop e Playbook Antislop | Revise a composição existente e sua linguagem. Cores têm função: tocando, seleção, atenção, risco ou Selo Ouro. Remova legendas que apenas repetem o título. |
| Qual interação traduz melhor a escolha do DJ? | UI/UX Pro Max | Compare opções para a tarefa concreta: escolher a cópia que fica, confirmar os limites de um recorte ou localizar uma preferência pelo teclado. Mantenha o vocabulário, os controles e a paleta do produto. |
| O que acontece de fato em tamanhos e estados diferentes? | UI Review com Playwright/WebKit | Confira conteúdo, foco e controles no desktop e a 375 px. Abra a ficha com um título longo, examine uma falha e navegue de volta. Para o player global, meça a posição do último controle com a barra visível. |
| O problema está no espaço, foco, movimento ou seleção? | Elixir Agent Kit | Escolha o fluxo específico: **layout-density**, **accessibility**, **responsive-layout**, **motion-design** ou **direct-interactions**. A troca de estado dos decks e a preferência por movimento reduzido devem coexistir. |

## Uma frente por página

| Página | Prova de uso |
|---|---|
| Biblioteca | Buscar pelo nome e combinar com um intervalo. Abrir a faixa certa pelo teclado. |
| Ficha da faixa | Ler título e artista longos. Ir direto à edição, ao volume ou aos marcadores. |
| Importações | Comparar as versões de uma música, identificar o que está selecionado e distinguir uma prévia de um download iniciado. |
| Repertório | Ler a distribuição do acervo e, separadamente, encontrar sugestões para a pasta escolhida. |
| Revisão de sugestões | Comparar o valor atual e o proposto antes de aprovar ou rejeitar. |
| Duplicatas | Ler os caminhos das cópias e identificar qual fica ao trocar a seleção. |
| Gêneros | Ler a regra de uma pasta, abrir a edição e cancelar. |
| Recuperação de arquivos | Localizar um arquivo, ler o motivo e o caminho e encontrar as opções disponíveis. |
| Montagem de sets | Selecionar um set no celular, ver sua sequência e abrir o mesmo set na cabine. |
| Discotecagem | Distinguir a preparação do transporte. Identificar o estado de A e B e entrar e sair do modo viagem pelo teclado. |
| Sets gravados | Encontrar uma gravação pela busca e abrir seu detalhe. |
| Detalhe do set gravado | Localizar um trecho no tempo e conferir o início e o fim do recorte antes de criar a faixa. |
| Fila de tarefas | Filtrar por estado, ler o assunto de uma tarefa e inspecionar uma falha. |
| Manutenção | Reconhecer a operação de biblioteca inteira, seu escopo e o efeito de confirmá-la. |
| Ajustes | Encontrar uma preferência, seu valor atual, sua faixa válida e o retorno da alteração. |

O menu e o reprodutor atravessam essas páginas. Confira o foco ao fechar o menu, a volta ao conteúdo e o acesso a marcadores, posição, volume e fechar com o reprodutor visível. Use uma cópia da biblioteca para experimentar ações de arquivo; a conferência visual da cabine pode acontecer com os dois decks parados.
