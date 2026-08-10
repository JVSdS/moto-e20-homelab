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

