# droid_lkm no Galaxy A36 (SM-A366E) — relatório de viabilidade

Data: 2026-11-03
Branch: `feat/gki-6.6-misc` (HEAD `557c289` + este relatório)
Device: SM-A366E, Android 17, build `A366EXXUCDZIF`
Kernel: `6.6.118-android15-8-34442516-user-abA366EXXUCDZIF-4k`

## Resposta curta

Os dois hooks pedidos existem e são instaláveis **no código**: as rotas de
resolução, as assinaturas BTF, os offsets e o gating batem com o kernel do
device (T1–T7).

O artefato compilado hoje **não carrega** nesse aparelho: o vermagic é
`6.6.127-…` e o device exige `6.6.118-…`. `check_modinfo()` recusa o `.ko`
antes de qualquer hook rodar. `CONFIG_MODULE_FORCE_LOAD` não está setado e
forçar/editar vermagic está fora de escopo por regra. É preciso recompilar
contra os headers 6.6.118 (T10).

## O que foi verificado

| # | Item | Resultado |
|---|---|---|
| T1 | Configs do kernel do device (`a36-kheaders/include/generated/autoconf.h`) | `KPROBES`, `KALLSYMS`, `KALLSYMS_ALL`, `DEBUG_INFO_BTF`, `CFI_CLANG`, `MODULES`, `MODVERSIONS`, `MODULE_UNLOAD`, `TRIM_UNUSED_KSYMS` ligados; `MODULE_FORCE_LOAD`, `MODULE_SIG_FORCE`, `RANDSTRUCT` desligados |
| T2 | Rotas de resolução (`hk_resolve` → `kallrecon_klp` → `kallsyms_name_to_addr`) | `create_new_namespaces` é símbolo local `t`, não `NOKPROBE`, não `.init`; alcançável |
| T3 | Assinaturas BTF × wrappers | `nsproxy *create_new_namespaces(unsigned long, task_struct*, user_namespace*, fs_struct*)`, `int copy_namespaces(unsigned long, task_struct*)`, `switch_task_namespaces`, `exit_task_namespaces`, `unshare_nsproxy_namespaces` — todas batem |
| T4 | Offsets BTF | `nsproxy` 72 B (`ipc_ns` 0x10, `mnt_ns` 0x18, `pid_ns_for_children` 0x20, `net_ns` 0x28…); `task_struct` 4800 B (`nsproxy` 0x870, `fs` 0x858, `cred` 0x820…); `ipc_namespace` 1272 B; `pid_namespace` 136 B |
| T5 | Headers do alvo × BTF | `ipc_namespace.h` mantém a ordem (`mq_mnt` L53 … `mnt_llist` L75, `ns` L77) igual ao BTF → BTF é do build do device |
| T6 | Uso de offset em runtime | `src/main/core/ds.h:28-160` usa `droid_lkm_layout_off()` para `task_struct`/`nsproxy`; offsets de compilação só em campos de `ipc_namespace` anteriores a `mnt_llist`/`ns` (mesma ordem) |
| T7 | Gating | sem os hooks críticos e sem `degrade=1`, `main.c` recusa o load com `-EOPNOTSUPP`; `droid_lkm_slot_init` ignora o retorno de `droid_lkm_nsproxy_hook_install` |
| T8 | Build CI | run `41590802923`, 7/7 jobs verdes, `android15-6.6` em 1m38s, gate de warnings passou |
| T9 | Vermagic | **bloqueio**: 6.6.127 ≠ 6.6.118 |

Detalhe do log de cada teste em `TESTES.md`.

## Build (T8)

Artefatos de `/tmp/opencode/art/droid_lkm-android15-6.6/`:

| arquivo | sha256 |
|---|---|
| `droid_lkm.ko` | `1ec4c53ea38347326995297e517c3d70f9fb74619926c21f4c98e6819f61287b` |
| `droid_lkm_misc.ko` | `341d9269b7b2885a0b2abb3a06fcfe87101f22d38e9de55d4dc2bf9e05b926c3` |
| `droid_lkm_vendor.ko` | `644bd4e010916fb8c66450992995c79d6f34545379179fa3b3ab6671f0fe5b7d` |

O `.ko` em `/sdcard/Download/droid_lkm-android15-6.6/` é byte-idêntico
(mesmo sha256), ou seja, também tem vermagic 6.6.127.

## Bloqueio: vermagic (T9)

```
artefato : 6.6.127-4k-g46a034eca005-dirty SMP preempt mod_unload modversions aarch64
device   : 6.6.118-android15-8-34442516-user-abA366EXXUCDZIF-4k SMP preempt mod_unload modversions aarch64
```

- `uname -r` do device = `6.6.118-android15-8-34442516-user-abA366EXXUCDZIF-4k`
  (`a36-kheaders/include/generated/utsrelease.h`).
- `check_modinfo()` compara o release e devolve `-ENOEXEC`; nada do módulo
  (nem `droid_lkm_layout_init`, nem kprobes) chega a rodar.
- `CONFIG_MODULE_FORCE_LOAD` não existe nesse kernel; usar `insmod -f`/forçar
  ou reescrever a string no `.ko` está proibido pelas regras do trabalho.
- Registry `ghcr.io/ylarod/ddk-min`: só existe uma receita para
  `android15-6.6` (tags `20260313` e `20260828` apontam para o mesmo config,
  criado em 2026-03-12, `KDIR=/opt/ddk/kdir/android15-6.6`), que gera
  6.6.127. Não há imagem 6.6.118 publicada.

## Riscos residuais (depois do rebuild 6.6.118)

1. `CONFIG_TRIM_UNUSED_KSYMS=1`: o `.ko` tem 203 símbolos `UND`; todos
   precisam estar na tabela de exportação do kernel Samsung. Os symbols dos
   hooks (`create_new_namespaces`/`copy_namespaces`) não são importados no
   link (resolvidos por kallsyms em runtime), então isso não afeta a rota,
   mas pode afetar utilitários (proc/sysctl etc.).
2. `__versions` do artefato tem tamanho 0: não há checagem de CRC por
   símbolo, o que facilita o rebuild (não exige `Module.symvers` casando
   CRC), mas também significa que incompatibilidades de ABI não serão
   detectadas no load — só em runtime.
3. CFI/KCFI: o módulo já traz os shims (`src/kcfi_safe.h`); o kernel do
   device tem `CONFIG_CFI_CLANG=1`. Precisa validar no device.
4. Layout: se o BTF runtime não for considerado confiável
   (`droid_lkm_layout_trusted()`), pidns/ipcns desligam e o load termina em
   `-EOPNOTSUPP` (comportamento esperado, não é crash).
5. `ipc_namespace` tem acesso direto por offset de compilação; hoje a ordem
   bate, mas um build com headers GKI puros (sem os campos Samsung) mudaria
   `mq_mnt`/`ns`. O rebuild tem que usar o header do build do device.

## Opções

- **A (recomendada):** compilar contra o source Samsung do build
  `A366EXXUCDZIF` (SM-A366E) no CI — baixar o tarball do
  opensource.samsung.com, `make modules_prepare` com a defconfig do device e
  rodar o mesmo `make VER=android15-6.6`. O vermagic passa a ser o do
  device; validar os 203 `UND` contra o `Module.symvers` gerado.
- **B:** achar/gerar uma imagem DDK com GKI 6.6.118 exato e fixar a tag no
  workflow (hoje não existe publicada).
- **C:** manter só a análise (T1–T9) e não carregar nada no aparelho.

Nenhuma dessas opções foi executada: A e B mudam o pipeline; C não muda
nada. A decisão é do usuário.

## Comandos para revisão (nada foi executado)

Com o artefato atual, o preflight do `install.sh` recusa:

```sh
su -c 'sh install.sh --ko /sdcard/Download/droid_lkm-android15-6.6/droid_lkm.ko'
# exit 2: vermagic release mismatch (6.6.127 vs 6.6.118)
```

Depois de um build 6.6.118, o dry-run mostra e o `--apply` executa:

```sh
su -c 'sh install.sh --ko /data/local/tmp/droid_lkm.ko'
su -c 'sh install.sh --ko /data/local/tmp/droid_lkm.ko' --apply
# insmod /data/local/tmp/droid_lkm.ko verbose=1
# dmesg | tail -n 60
```

O `install.sh` não apaga `loading`, `insmod.inflight`, `insmod.crash` nem
`load.log`; se algum existir, ele para e pede inspeção.

## Arquivos relevantes

- `src/main/core/ds.h` — acessores por offset vivo.
- `src/main/slot/ds_slot.c` — instalação de `create_new_namespaces` /
  `copy_namespaces`.
- `src/hook/ds_hook.c` — rotas e estado crítico.
- `src/main/core/main.c` — gating e recusa sem hooks críticos.
- `module/customize.sh`, `module/service.sh` — instalação por KMI (Magisk).
- `install.sh` — preflight de vermagic + dry-run/`--apply`.
- `TESTES.md` — T0–T9 com comandos e saídas.
