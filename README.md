# Homelab no Moto E20 — DevSecOps na prática

Projeto de laboratório pessoal para aplicar, na prática, conceitos de infraestrutura e segurança estudados no roadmap de DevSecOps.

A ideia central: transformar um celular Android sem uso (Moto E20) num nó Linux remoto, e usar esse ambiente para praticar hands-on os mesmos princípios vistos em teoria — privilégio mínimo, autenticação segura, camadas de segurança, observabilidade e outras coisas vistas durante meu aprendizado.

## Status atual

- [x] Ambiente Linux funcional no celular (Termux + proot-distro)
- [x] Usuário não-root dedicado, sem privilégios desnecessários
- [x] Acesso remoto via SSH com autenticação por chave (sem senha)
- [x] Hardening do SSH (sem login root, sem senha, MaxAuthTries)
- [x] fail2ban configurado (detecção funcional; bloqueio automático limitado pelo ambiente — ver seção abaixo)
- [x] Aplicação de exemplo (FastAPI) rodando como serviço persistente
- [x] Watchdog via cron (auto-recuperação se a aplicação cair)
- [x] Dashboard web com métricas do sistema (RAM, armazenamento e bateria; CPU indisponível — ver seção abaixo)
- [x] Autenticação HTTP Basic Auth protegendo API e dashboard
- [x] Bateria real integrada ao dashboard via ponte Termux:API
- [x] Inicialização centralizada e idempotente dos serviços

## Índice

- [Arquitetura](#arquitetura)
- [Por que Debian, e não Arch ou Ubuntu](#por-que-debian-e-não-arch-ou-ubuntu)
- [Decisões de segurança](#decisões-de-segurança-tomadas-até-aqui)
- [Problemas encontrados e soluções](#problemas-encontrados-e-soluções)
- [Fail2ban](#fail2ban-detecção-funciona-bloqueio-automático-não-nesse-ambiente)
- [Investigação: root real](#investigação-tentativa-de-obter-root-real-bootloader-unlock)
- [FastAPI](#aplicação-de-exemplo-fastapi-como-serviço-persistente)
- [Watchdog](#watchdog-auto-recuperação-via-cron)
- [Dashboard e limitação de CPU](#dashboard-web-e-a-limitação-de-leitura-de-cpu)
- [Autenticação](#autenticação-protegendo-a-api-e-o-dashboard)
- [Bateria](#bateria-real-via-ponte-termuxapi)
- [Inicialização](#script-de-inicialização-único-e-idempotente)

## Arquitetura

```
[PC] --SSH (chave ed25519, porta 8022)--> [Moto E20]
                                              └── Termux
                                                    └── proot-distro
                                                          └── Debian (armhf)
                                                                └── usuário `devops` (não-root)
```

## Por que Debian, e não Arch ou Ubuntu

O hardware usa arquitetura ARMv8, mas o Android expõe apenas um userspace 32-bit compatível com ARMv7, sem suporte a `arm64-v8a` — confirmado via:

```bash
uname -m              # armv8l (userspace 32 bits)
getprop ro.product.cpu.abilist   # armeabi-v7a,armeabi (sem arm64-v8a)
```

O Arch Linux ARM descontinuou suporte a armv7 (32 bits), então não roda nesse aparelho. O Debian ainda mantém suporte oficial a `armhf`, e é uma escolha por ser uma das distros mais usadas em servidores e VPS de verdade.

## Decisões de segurança tomadas até aqui

| Decisão | Motivo |
|---|---|
| Usuário `devops` dedicado, sem rodar tudo como root | Least privilege — mesmo princípio de papéis personalizados do IAM |
| Autenticação SSH por chave (ed25519), não por senha | Elimina autenticação por senha e reduz a superfície para ataques de força bruta; a chave privada permanece protegida por passphrase |
| Chave privada protegida por passphrase | Mesmo se o arquivo da chave vazar, ainda é necessária a senha para usá-la |
| SSH na porta 8022, não 22 | O `sshd` dentro do proot não consegue fazer bind na porta privilegiada 22 nesse ambiente; 8022 é usada como alternativa |

## Problemas encontrados e soluções

Principais problemas encontrados durante a montagem inicial (os mais relevantes são detalhados nas seções específicas abaixo):

- **`proot-distro install archlinux` falhou** com erro de arquitetura → resolvido trocando para Debian (ver seção acima).
- **`sshd` não conseguia abrir a porta 22** (`Permission denied`) → nesse ambiente, o `sshd` dentro do proot não consegue fazer bind na porta privilegiada; resolvido mudando para a porta 8022 em `/etc/ssh/sshd_config`.
- **`ssh-copy-id` falhou com aviso de host key alterada** → esperado, pois o servidor SSH mudou (do nativo do Termux para o do Debian); resolvido com `ssh-keygen -R`.

## Fail2ban: detecção funciona, bloqueio automático não (nesse ambiente)

Depois do SSH hardening, tentei configurar `fail2ban` para banir automaticamente IPs com tentativas repetidas de login falho. O processo envolveu resolver várias camadas de limitação do ambiente proot:

- **UFW/iptables não funciona no proot**: falha com `Couldn't determine iptables version`, porque o proot não fornece acesso privilegiado ao subsistema de rede do kernel Android (esse kernel é o do Android, fora do alcance do container simulado).
- **rsyslog não escrevia `/var/log/auth.log`** por padrão nessa imagem mínima (faltava `/etc/rsyslog.d/50-default.conf`). Mesmo depois de criar a regra manualmente, o log continuou vazio — provável limitação do socket `/dev/log` dentro do proot.
- **Solução**: fazer o próprio `sshd` escrever logs direto em arquivo, contornando o syslog inteiro (`sshd -E /var/log/auth.log`).
- **Filtro padrão do fail2ban (incluindo modo `aggressive`) não reconhecia** o formato de mensagem `Connection closed by authenticating user ... [preauth]`, gerado nas versões mais recentes do OpenSSH. Resolvido escrevendo um filtro customizado (`/etc/fail2ban/filter.d/sshd-custom.conf`), validado com `fail2ban-regex` antes de aplicar.
- **Resultado parcial**: o fail2ban passou a **detectar** corretamente as tentativas de força bruta (`Currently banned: 1` aparece no status). Porém, a ação de ban padrão usa `nftables`, que — assim como o UFW — precisa de acesso real ao kernel de rede para criar regras. Nesse ambiente, o ban é registrado internamente, mas **não bloqueia a conexão de fato** (testado: consegui logar normalmente mesmo com o IP marcado como banido).

**Conclusão**: nesse ambiente proot, sem acesso privilegiado ao netfilter do kernel Android, é possível implementar a camada de **detecção** de ataques, mas não a de **prevenção automática por bloqueio de rede**. Em uma VPS Linux convencional com acesso ao netfilter/nftables, essa abordagem teria condições de realizar também o bloqueio automático, embora a configuração possa exigir ajustes conforme o ambiente.

Alternativa considerada e descartada: trocar a ação de ban para editar `sshd_config` (`DenyUsers`) e reiniciar o serviço. Funcionaria, mas derrubaria todas as conexões SSH ativas a cada ban (não só a do IP infrator), o que é inaceitável em qualquer cenário real.

## Investigação: tentativa de obter root real (bootloader unlock)

Depois de esbarrar nas limitações do proot (UFW, fail2ban sem bloqueio automático), investiguei se valia a pena desbloquear o bootloader do Moto E20 e rootear o aparelho de verdade, para ter acesso ao kernel real e resolver essas limitações na raiz.

**Diagnóstico técnico:**

- Confirmado via `getprop ro.product.cpu.abilist`: o aparelho roda em modo 32 bits (armv7), sem `arm64-v8a` — hardware Unisoc T606.
- Modelo confirmado: **XT2155-1**, codinome **aruba**, variante **RETBR** (Brasil/Manaus), build **RONS31.267-94-14**.
- Segui o processo padrão de desbloqueio Motorola: ativei "Desbloqueio OEM" nas opções de desenvolvedor, instalei drivers corretos (o driver padrão do Windows não reconhece o modo Fastboot — foi necessário instalar manualmente o Google USB Driver via Gerenciador de Dispositivos), confirmei comunicação via `fastboot devices`.
- `fastboot oem get_unlock_data`, `fastboot oem unlock`, `fastboot oem device-info`, `fastboot flashing unlock` e `fastboot flashing get_unlock_ability` retornam todos **`unknown cmd`** ou **`Not implement`** — nenhuma interface pública de desbloqueio está exposta nesse bootloader.
- `fastboot oem get_identifier_token` funciona e retorna um token, assim como `getvar all` expõe campos como `tokenp1`, `unlock_raw_data` e `lcs: 5` — indícios de um mecanismo de identificação existente, mas sem uma interface documentada publicamente para completá-lo.

**Evidências externas:**

- Outros usuários com o mesmo aparelho exato (Moto E20 "aruba", diferentes variantes XT2155-x) relataram publicamente o mesmo erro, em Windows e Linux, incluindo tentativas com a ferramenta comunitária de desbloqueio Unisoc baseada em `get_identifier_token` (que falhou com `Unlock bootloader fail` mesmo em outro Unisoc T606).
- O suporte oficial da Motorola, questionado sobre esse modelo especificamente, respondeu que a empresa não oferece suporte a esse tipo de modificação e que o aparelho não está no programa de desbloqueio de bootloader deles.
- Existe uma vulnerabilidade documentada e publicamente divulgada para o Moto E20 (**CVE-2022-3917**, encontrada pela Pen Test Partners): um subcomando `fastboot oem pull` não documentado permitia leitura de RAM/partições via cold boot. Duas ressalvas importantes: (1) foi corrigida em firmware com SPL de 2022-08-05 ou posterior, e a build deste aparelho (`267-94-14`) é posterior à versão que recebeu a correção (`267-38-8`), então provavelmente já não é explorável aqui; (2) mesmo funcionando, era uma vulnerabilidade de **leitura**, não de escrita — não teria dado root de qualquer forma.
- Não foi encontrado nenhum método documentado e reproduzível de desbloqueio de bootloader, boot temporário via RAM, ou root para o XT2155-1 nessa ou em builds próximas.

**Decisão:** não prosseguir. As alternativas restantes (ferramentas de nível SPD/FDL, test point físico, exploração de firmware sem documentação confiável) têm risco real de brick permanente (não recuperável), documentação escassa especificamente para esse hardware, e nenhum relato de sucesso da comunidade mesmo entre quem tentou. O retorno esperado não justifica o risco.

**Confirmação adicional (FDL/BootROM):** avaliei também a rota de comunicação direta com o chip via BootROM/FDL (camada abaixo do bootloader, usada por ferramentas de assistência técnica). Encontrei um relato público de alguém tentando exatamente esse caminho no mesmo aparelho (comando `unlock_bootloader` com arquivo `signature.bin`, método SPD/Unisoc documentado pela comunidade Hovatek) — resultado: `FAILED (remote: not implemented.)`. Ou seja, nem essa camada mais baixa consegue contornar o bloqueio nesse hardware específico. Esse foi o último caminho tecnicamente plausível considerado.

Também vale registrar: existe uma ferramenta legítima de recuperação para esse modelo (SPD Upgrade Tool + firmware oficial `.pac`), usada para restaurar o aparelho ao estado de fábrica em caso de problemas de software. Isso não abre nenhum caminho para desbloqueio — é só uma rede de segurança separada, útil de se conhecer, mas que não muda a conclusão acima.

O projeto segue sem root real nesse aparelho — as limitações relacionadas (UFW/nftables sem funcionar) permanecem documentadas como restrições conhecidas do ambiente proot, não como pendências a resolver.

## Aplicação de exemplo: FastAPI como serviço persistente

Depois de resolver o hardening de rede, subi uma aplicação real para validar a esteira completa: escrever código, isolar dependências, rodar como serviço e sobreviver a desconexões — sem depender de systemd (indisponível no proot).

**Decisões:**

- **Ambiente virtual Python (`venv`)**, em vez de instalar pacotes globalmente: evita conflito entre pacotes gerenciados pelo `apt` (Debian) e pelo `pip`. Na primeira tentativa, `pip install fastapi --break-system-packages` falhou tentando desinstalar uma dependência (`typing_extensions`) já instalada via `apt`, sem o arquivo de controle que o pip precisa para gerenciar upgrades com segurança. Isolar em `venv` resolveu de forma definitiva, e é boa prática de qualquer forma.
- **`nohup` + redirecionamento de log** (`nohup uvicorn ... > app.log 2>&1 &`), em vez de um gerenciador de processos completo: sem systemd real no proot, essa é a forma mais simples de manter um processo rodando além da sessão SSH atual. Testado explicitamente: encerrei a sessão SSH e reconectei — a aplicação continuou respondendo.

**Limitação conhecida:** diferente de um serviço gerenciado por systemd (ou supervisord), esse processo **não reinicia sozinho** se cair (erro na aplicação, reinício do celular, etc.). Isso é uma lacuna real, considerada aceitável nesta fase do projeto.

**Endpoint exposto:** `GET /` retorna um JSON simples de health-check (status, hostname, timestamp) — sem lógica de negócio relevante; o objetivo desta etapa foi a infraestrutura de deploy, não a aplicação em si.

## Watchdog: auto-recuperação via cron

A limitação do `nohup` (processo não reinicia sozinho se cair) foi resolvida com um script de verificação agendado via `cron`.

**Como funciona:**

```
A cada 1 minuto (cron):
  watchdog.sh verifica se http://localhost:8000 responde 200
    → se sim: registra OK no log
    → se não: reinicia a aplicação (nohup uvicorn ... &) e registra a falha
```

**Decisões:**

- Script (`watchdog.sh`) roda como usuário `devops`, não root — mantém o princípio de privilégio mínimo já aplicado no resto do projeto.
- `cron`, assim como SSH e fail2ban, não inicia sozinho nesse ambiente (sem systemd). Inicialmente isso exigia inicialização manual a cada reinício; posteriormente, o `start-homelab.sh` passou a automatizar essa etapa (ver seção "Script de inicialização único e idempotente").
- Log dedicado (`watchdog.log`) separado do log da aplicação (`app.log`), para diferenciar "a aplicação disse algo" de "o watchdog tomou uma ação".

**Testado com falha simulada:** matei o processo manualmente (`pkill -f uvicorn`) e confirmei, no ciclo seguinte do cron (até 1 minuto depois), que o watchdog detectou a falha, reiniciou a aplicação (PID novo, confirmando restart real) e voltou a reportar OK na checagem seguinte.


## Dashboard web e a limitação de leitura de CPU

Depois do watchdog, adicionei um endpoint (`/api/status`) e uma página web simples (`/dashboard`) mostrando métricas do sistema com atualização periódica — o dashboard consulta `/api/status` a cada 5s via JavaScript.

**Funcionou sem problemas:** uso de RAM e armazenamento, lidos via `psutil` e `shutil.disk_usage`.

**Não funcionou: percentual de uso de CPU.** `psutil.cpu_percent()` sempre retornava `0%`, mesmo gerando carga real no processador (testado com `yes > /dev/null &`). Investigação:

- Comparei duas leituras de `/proc/stat` (fonte que o `psutil` usa para calcular uso de CPU) com 2 segundos de intervalo, dentro do proot — os valores vieram **idênticos**, mesmo logo após gerar carga real. Indica que, nesse ambiente, o `/proc/stat` exposto pelo proot não reflete alterações em tempo real do kernel.
- Testei o mesmo `cat /proc/stat` **fora do proot**, direto no Termux nativo — resultado: `Permission denied`.

**Conclusão:** é uma restrição do próprio ambiente Android, que impede o Termux sem privilégios de acessar `/proc/stat` diretamente — mesmo fora do proot. O proot aparenta contornar o bloqueio (o arquivo "parece" legível), mas os valores observados não refletem alterações em tempo real.

**Nota de precisão:** o que foi provado é que essa abordagem específica (leitura direta de `/proc/stat`) não funciona sem privilégios — não que seja impossível obter a métrica por qualquer via. Testei essa hipótese instalando `htop` (ferramenta madura, escrita em C, usada amplamente em ambientes Termux) diretamente no Termux nativo, fora do proot. Resultado: todos os núcleos além do 0 aparecem como `offline`, todo processo (inclusive o próprio `htop` rodando) mostra `CPU% = N/A`, e o `Load average` retorna `nan nan nan`. Mesmo uma ferramenta consolidada, sem depender de `/proc/stat` da forma ingênua que o `psutil` usa, esbarra na mesma restrição.

**Conclusão:** as abordagens testadas até aqui — leitura de `/proc/stat`, `psutil`, `htop` e `Termux:API` — não forneceram uma métrica de uso de CPU confiável. A `Termux:API` foi testada posteriormente (ver seção "Bateria real via ponte Termux:API") e também não oferece um comando específico para essa métrica.

**Decisão por ora:** o dashboard exibe "N/D (métrica indisponível)" no lugar do percentual de CPU, em vez de mostrar um número enganoso (0% constante poderia ser lido como "celular sempre ocioso", quando na verdade é "não é possível medir com o método atual"). RAM e armazenamento continuam confiáveis e são exibidos normalmente.

## Autenticação: protegendo a API e o dashboard

`/api/status` e `/dashboard` estavam publicamente acessíveis a qualquer um na mesma rede, sem nenhuma barreira. Adicionei autenticação para fechar essa lacuna.

**Solução escolhida: HTTP Basic Auth**, via middleware do Starlette, em vez de uma tela de login customizada:

- Aplica-se a toda rota, exceto `/` (health-check simples, mantido público de propósito).
- Credencial única (usuário fixo + senha aleatória gerada com `secrets.token_hex(32)`), guardada em `.env` (nunca commitado — protegido tanto pelo `.gitignore` da pasta do serviço quanto pelo da raiz do repositório).
- Comparação de senha feita com `secrets.compare_digest`, em vez de `==`, seguindo uma abordagem resistente a ataques de timing.
- Como o `StaticFiles` do FastAPI não tem suporte nativo a autenticação por header, a proteção foi implementada como middleware — cobre tanto os endpoints da API quanto os arquivos estáticos do dashboard de forma unificada, sem precisar duplicar lógica.

**Limitação conhecida:** HTTP Basic Auth envia as credenciais codificadas em Base64 a cada requisição; Base64 não fornece criptografia, o que deixa as credenciais vulneráveis à interceptação por um atacante capaz de observar o tráfego da rede. Isso é aceitável neste projeto porque a API foi projetada para uso exclusivamente dentro de uma rede local controlada, sem requisito de segurança contra esse tipo de ameaça. Para exposição fora da rede local, o serviço deveria ser protegido por HTTPS. O problema fundamental é a ausência de criptografia no transporte, independentemente do mecanismo de autenticação utilizado (Basic Auth, sessão, JWT etc.).

**Validado com bateria de 7 testes** (rota pública sem credenciais, rota protegida sem credenciais, com credenciais corretas, com credenciais erradas, dashboard sem/com credenciais, teste visual no navegador, e confirmação de que `.env` nunca aparece no `git status`) — todos passaram como esperado.

**Lição aprendida:** durante a sincronização dos arquivos para o repositório, a função "Download Folder" da extensão SFTP do VS Code sobrescreveu vários arquivos locais (`main.py`, `requirements.txt`, `static/index.html`) com conteúdo vazio, sem aviso de erro visível. Recuperado copiando o conteúdo real diretamente do celular (fonte da verdade) via `cat` na sessão SSH. "Sincronizou sem erro aparente" não é garantia de que o conteúdo chegou íntegro — passei a sempre verificar conteúdo (`wc -l`, `cat`) depois de qualquer sincronização automática antes de commitar.

## Bateria real via ponte Termux:API

A investigação da limitação de CPU (seção acima) deixou uma pista para investigar: o pacote `Termux:API`, que acessa informações do sistema através das APIs do próprio Android, em vez de depender diretamente de `/proc`. Testei essa via — não resolveu CPU, mas resolveu bateria, que também estava pendente.

**CPU:** o `Termux:API` não oferece comando para uso de CPU. A investigação completa está na seção [Dashboard web e a limitação de leitura de CPU](#dashboard-web-e-a-limitação-de-leitura-de-cpu).

**Bateria funcionou.** `termux-battery-status` retorna dados reais (percentual, status de carga, temperatura, saúde) — mas só funciona no Termux nativo, fora do proot, e a aplicação FastAPI roda dentro do proot. Foi necessário construir uma ponte:

```
Termux nativo                    proot (Debian)
─────────────                    ───────────────
battery-bridge.sh (loop 30s)
  → termux-battery-status
  → escreve em battery.json  ──→  mesmo arquivo, lido via
     (caminho físico          caminho compartilhado
     compartilhado com o          (/home/devops/apps/
     proot)                        healthcheck/battery.json)
                                        ↓
                                  main.py lê o arquivo
                                  e expõe via /api/status
```

**Problema encontrado:** chamadas a `termux-battery-status` feitas pelo script em segundo plano (via `nohup`) ficavam bloqueadas indefinidamente, mesmo funcionando normalmente quando rodado de forma interativa.

**Causa:** otimização de bateria do Android no dispositivo Motorola, aparentemente fazendo com que o app companheiro Termux:API deixasse de responder a chamadas feitas em background.

**Solução:** desativação da otimização de bateria especificamente para o app Termux:API (`Ajustes > Apps > Termux:API > Bateria > Sem restrições`) e reinicialização completa do Termux.

**Decisão de arquitetura:** a ponte roda como um script simples em loop (`while true; do ...; sleep 30; done`) em vez de um agendamento mais sofisticado, porque `cron` só existe dentro do proot — o Termux nativo (onde o `termux-battery-status` precisa rodar) não tem acesso a ele.

**Resultado:** dashboard agora exibe percentual de bateria e status de carga (carregando/descarregando), atualizados a cada 30 segundos, junto com RAM e armazenamento.

## Script de inicialização único e idempotente

Toda vez que o processo do Termux era encerrado (reinício do celular, app fechado pelo sistema, etc.), era necessário religar manualmente cinco componentes espalhados em duas camadas diferentes (SSH, cron, fail2ban e a aplicação dentro do proot; a ponte de bateria no Termux nativo) — repetitivo e propenso a esquecimento. Consolidei tudo em dois scripts encadeados.

**Estrutura:**

```
~/start-homelab.sh (Termux nativo)
  ├─ verifica/inicia battery-bridge.sh
  └─ chama proot-distro login debian -- /root/start-all.sh
       ├─ verifica/inicia SSH
       ├─ verifica/inicia cron
       ├─ verifica/inicia fail2ban
       └─ verifica/inicia FastAPI
```

**Decisão de design: idempotência.** A primeira versão simplesmente iniciava tudo sem checar se já estava rodando — rodar o script duas vezes seguidas duplicou o processo da aplicação (dois `uvicorn` disputando a porta 8000). Corrigido adicionando uma verificação (`pgrep`) antes de cada ação: cada componente só é iniciado se ainda não estiver ativo, tornando seguro executar o script repetidamente sem duplicar os processos já ativos.

**Uso:** um único comando (`~/start-homelab.sh`, no Termux nativo) substitui a sequência manual de comandos que era necessária sempre que o processo do Termux era encerrado.