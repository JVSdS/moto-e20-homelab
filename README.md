# Homelab no Moto E20 — DevSecOps na prática

Projeto de laboratório pessoal para aplicar, na prática, conceitos de infraestrutura e segurança estudados no roadmap de DevSecOps.

A ideia central: transformar um celular Android sem uso (Moto E20) num nó Linux remoto, e usar esse ambiente para praticar hands-on os mesmos princípios vistos em teoria — privilégio mínimo, autenticação segura, camadas de segurança, observabilidade e outras coisas vistas durante meu aprendizado.

## Status atual

- [x] Ambiente Linux funcional no celular (Termux + proot-distro)
- [x] Usuário não-root dedicado, sem privilégios desnecessários
- [x] Acesso remoto via SSH com autenticação por chave (sem senha)

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
