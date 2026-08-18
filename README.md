# Homelab no Moto E20 — DevSecOps na prática

Projeto de laboratório pessoal para aplicar, na prática, conceitos de infraestrutura e segurança estudados no roadmap de DevSecOps.

A ideia central: transformar um celular Android sem uso (Moto E20) num nó Linux remoto, e usar esse ambiente para praticar hands-on os mesmos princípios vistos em teoria — privilégio mínimo, autenticação segura, camadas de segurança, observabilidade e outras coisas vistas durante meu aprendizado.

## Status atual

- [x] Ambiente Linux funcional no celular (Termux + proot-distro)
- [x] Usuário não-root dedicado, sem privilégios desnecessários
- [x] Acesso remoto via SSH com autenticação por chave (sem senha)
- [x] Hardening do SSH (sem login root, sem senha, MaxAuthTries)
- [x] fail2ban configurado (detecção funcional; bloqueio automático limitado pelo ambiente — ver seção abaixo)

## Arquitetura

```
[PC] --SSH (chave ed25519, porta 8022)--> [Moto E20]
                                              └── Termux
                                                    └── proot-distro
                                                          └── Debian (armhf)
                                                                └── usuário `devops` (não-root)
```

## Por que Debian, e não Arch ou Ubuntu

Meu objetivo inicial era usar o Arch, mas o Moto E20 usa um chip que roda o Android em modo 32 bits (armv7), confirmado via:

```bash
uname -m              # armv8l (userspace 32 bits)
getprop ro.product.cpu.abilist   # armeabi-v7a,armeabi (sem arm64-v8a)
```

O Arch Linux ARM descontinuou suporte a armv7 (32 bits), então não roda nesse aparelho. O Debian ainda mantém suporte oficial a `armhf`, e é uma escolha por ser uma das distros mais usadas em servidores e VPS de verdade.

## Decisões de segurança tomadas até aqui

| Decisão | Motivo |
|---|---|
| Usuário `devops` dedicado, sem rodar tudo como root | Least privilege — mesmo princípio de papéis personalizados do IAM |
| Autenticação SSH por chave (ed25519), não por senha | Evita que a senha trafegue pela rede; resistente a força bruta |
| Chave privada protegida por passphrase | Mesmo se o arquivo da chave vazar, ainda é necessária a senha para usá-la |
| SSH na porta 8022, não 22 | Necessidade técnica do ambiente proot (processos não-root não podem abrir portas < 1024); irei decidir de mantenho com a evolução do projeto |

## Problemas encontrados e soluções

- **`proot-distro install archlinux` falhou** com erro de arquitetura → resolvido trocando para Debian (ver seção acima).
- **`sshd` não conseguia abrir a porta 22** (`Permission denied`) → causa: porta privilegiada não pode ser aberta por processo sem root real; resolvido mudando para porta 8022 em `/etc/ssh/sshd_config`.
- **`ssh-copy-id` falhou com aviso de host key alterada** → esperado, pois o servidor SSH mudou (do nativo do Termux para o do Debian); resolvido com `ssh-keygen -R`.

## Fail2ban: detecção funciona, bloqueio automático não (nesse ambiente)

Depois do SSH hardening, tentei configurar `fail2ban` para banir automaticamente IPs com tentativas repetidas de login falho. O processo envolveu resolver várias camadas de limitação do ambiente proot:

- **UFW/iptables não funciona no proot**: falha com `Couldn't determine iptables version`, porque o proot não tem acesso real ao subsistema de rede do kernel (esse kernel é o do Android, fora do alcance do container simulado).
- **rsyslog não escrevia `/var/log/auth.log`** por padrão nessa imagem mínima (faltava `/etc/rsyslog.d/50-default.conf`). Mesmo depois de criar a regra manualmente, o log continuou vazio — provável limitação do socket `/dev/log` dentro do proot.
- **Solução**: fazer o próprio `sshd` escrever logs direto em arquivo, contornando o syslog inteiro (`sshd -E /var/log/auth.log`).
- **Filtro padrão do fail2ban (incluindo modo `aggressive`) não reconhecia** o formato de mensagem `Connection closed by authenticating user ... [preauth]`, gerado nas versões mais recentes do OpenSSH. Resolvido escrevendo um filtro customizado (`/etc/fail2ban/filter.d/sshd-custom.conf`), validado com `fail2ban-regex` antes de aplicar.
- **Resultado parcial**: o fail2ban passou a **detectar** corretamente as tentativas de força bruta (`Currently banned: 1` aparece no status). Porém, a ação de ban padrão usa `nftables`, que — assim como o UFW — precisa de acesso real ao kernel de rede para criar regras. Nesse ambiente, o ban é registrado internamente, mas **não bloqueia a conexão de fato** (testado: consegui logar normalmente mesmo com o IP marcado como banido).

**Conclusão**: nesse ambiente (proot sem kernel real), é possível implementar a camada de **detecção** de ataques, mas não a de **prevenção automática por bloqueio de rede**. Numa VPS real (com kernel próprio e acesso a `netfilter`/`nftables`), essa mesma configuração de fail2ban funcionaria de ponta a ponta sem ajustes adicionais — é uma limitação específica de rodar Linux dentro de um container não-privilegiado sobre Android, não um erro de configuração.

Alternativa considerada e descartada: trocar a ação de ban para editar `sshd_config` (`DenyUsers`) e reiniciar o serviço. Funcionaria, mas derrubaria todas as conexões SSH ativas a cada ban (não só a do IP infrator), o que é inaceitável em qualquer cenário real.

## Investigação: tentativa de obter root real (bootloader unlock)

Depois de esbarrar nas limitações do proot (UFW, fail2ban sem bloqueio automático), investiguei se valia a pena desbloquear o bootloader do Moto E20 e rootear o aparelho de verdade, para ter acesso ao kernel real e resolver essas limitações na raiz.

**Diagnóstico técnico:**

- Confirmado via `getprop ro.product.cpu.abilist`: o aparelho roda em modo 32 bits (armv7), sem `arm64-v8a` — hardware Unisoc T606.
- Modelo confirmado: **XT2155-1**, codinome **aruba**, variante **RETBR** (Brasil/Manaus), build **RONS31.267-94-14**.
- Segui o processo padrão de desbloqueio Motorola: ativei "Desbloqueio OEM" nas opções de desenvolvedor, instalei drivers corretos (o driver padrão do Windows não reconhece o modo Fastboot — foi necessário instalar manualmente o Google USB Driver via Gerenciador de Dispositivos), confirmei comunicação via `fastboot devices`.
- `fastboot oem get_unlock_data`, `fastboot oem unlock`, `fastboot oem device-info`, `fastboot flashing unlock` e `fastboot flashing get_unlock_ability` retornam todos **`unknown cmd`** ou **`Not implement`** — nenhuma interface pública de desbloqueio está exposta nesse bootloader.
- `fastboot oem get_identifier_token` funciona e retorna um token, assim como `getvar all` expõe campos como `tokenp1`, `unlock_raw_data` e `lcs: 5` — indícios de um mecanismo de identificação existente, mas sem uma interface documentada publicamente para completá-lo.

**Pesquisa comunitária:**

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
- `cron`, assim como SSH e fail2ban, não inicia sozinho no boot nesse ambiente (sem systemd) — precisa ser iniciado manualmente (`cron`, como root) a cada sessão nova do Termux.
- Log dedicado (`watchdog.log`) separado do log da aplicação (`app.log`), para diferenciar "a aplicação disse algo" de "o watchdog tomou uma ação".

**Testado com falha simulada:** matei o processo manualmente (`pkill -f uvicorn`) e confirmei, no ciclo seguinte do cron (até 1 minuto depois), que o watchdog detectou a falha, reiniciou a aplicação (PID novo, confirmando restart real) e voltou a reportar OK na checagem seguinte.
