# TESTES — hooks de namespace (SM-A366E / 6.6.118)

Log de verificação estática. Nada aqui foi executado no aparelho:
`insmod`, `/data/adb`, reboot e carga de `.ko` são passos do usuário.

Ambiente: Termux + PRoot Ubuntu. `uname -r` é falso
(`6.17.0-PRoot-Distro`), então `/proc/kallsyms` e `/sys/kernel/btf/vmlinux`
não refletem o kernel real e não foram usados como prova.

## 2026-11-03 — T0: BTF do kernel alvo

Fonte: dump BTF raw do device, salvo em `~/a36-btf`.

```
$ ls -l ~/a36-btf
-rw------- 1 root root 6386444 ... /data/data/com.termux/files/home/a36-btf
$ sha256sum ~/a36-btf
89536540d18af897c51ab23736c3d734690200cfc6c6bc75f866609544680ef2
$ python3 /tmp/opencode/btfdump.py ~/a36-btf
BTF version=1 flags=0 types=146806
```

Parser próprio (`/tmp/opencode/btfdump.py`, sem dependências). Bug inicial
corrigido: `unknown kind 7 at off 25456` — kinds sem payload extra são
`0,2,7,8,9,10,11,12,16,18`; `FWD` (7) estava sendo lido como se tivesse
membro.

## 2026-11-03 — T1: configs do kernel alvo

`~/a36-kheaders/include/generated/autoconf.h`:

```
#define CONFIG_KPROBES 1
#define CONFIG_KALLSYMS 1
#define CONFIG_KALLSYMS_ALL 1
#define CONFIG_DEBUG_INFO_BTF 1
#define CONFIG_CFI_CLANG 1
#define CONFIG_MODULES 1
#define CONFIG_KPROBE_EVENTS 1
```

Consequência: kprobe é rota válida; símbolos locais (`t`) aparecem em
kallsyms (`KALLSYMS_ALL`); BTF existe (o Type_info pode validar offsets);
CFI exige os stubs `__cfi_*` (HooKern já segue branch puro até o corpo CFI).

## 2026-11-03 — T2: cadeia de resolução de símbolo

Leitura estática (sem execução):

- `src/main/core/main.c` → `droid_lkm_hk_resolve()` → `droid_lkm_sym()`.
- `HooKern/lib/hk.c` → `hk_resolve_cfi()` (guardado por `g_cfg.resolve` e
  `g_exiting`), `hk_follow_stub()`/`hk_read_insn()`/`hk_insn_is_bti()`
  (BTI `0xD503245F/249F/24DF/251F`), segue branch puro
  `(insn & 0xFC000000) == 0x14000000` por até `HK_STUB_FOLLOW` (8) saltos.
- `KallRecon/lib/core.c` → `find_kallsyms_base_once()` →
  `kr_discover_layout()` → `fast_find_klp()` (se `KALLRECON_FAST_BOOT` e
  sem `klseqs_addr`) → senão `kallsyms_name_to_addr("kallsyms_lookup_name")`.
  `find_kallsyms_base()` é idempotente (`ks_lock`/`ks_done`).
- `KallRecon/lib/symbol.c:494` → `kallsyms_name_to_addr()` percorre a
  tabela token-encoded; inclui símbolo local `t`. `lib/fastboot.c` exige
  match exato com sufixo `$`/`.` (LTO).
- `Type_info/lib/lib.c` → `ti_init()` usa
  `ti_res.name_to_addr("__start_BTF")` / `__stop_BTF` (não
  `/sys/kernel/btf`) e resolve `modules` para o notifier de BTF de módulo.

Veredito: **`create_new_namespaces` é alcançável**, inclusive sendo `static`
(local `t`) — desde que KallRecon recupere `kallsyms_lookup_name`. Com o
endereço em mãos o kprobe anexa (não é `NOKPROBE_SYMBOL`; não é `.init`).
Sem essa recuperação não existe rota "só por endereço".

## 2026-11-03 — T3: assinaturas no BTF vs. wrappers do módulo

```
### FUNC create_new_namespaces  (type_id=80644, linkage=0)
 nsproxy * create_new_namespaces(unsigned long flags, task_struct *tsk,
                                 user_namespace *user_ns, fs_struct *new_fs)
### FUNC copy_namespaces  (type_id=79763, linkage=0)
 int copy_namespaces(unsigned long flags, task_struct *tsk)
### FUNC switch_task_namespaces  (type_id=132701, linkage=0)
 void switch_task_namespaces(task_struct *p, nsproxy *new)
### FUNC exit_task_namespaces  (type_id=90799, linkage=0)
 void exit_task_namespaces(task_struct *p)
### FUNC unshare_nsproxy_namespaces  (type_id=140281, linkage=0)
 int unshare_nsproxy_namespaces(unsigned long unshare_flags,
                                nsproxy **new_nsp, cred *new_cred,
                                fs_struct *new_fs)
### FUNC check_unshare_flags
   NOT PRESENT AS FUNC
```

`create_new_namespaces` bate com `droid_lkm_cnn_wrap(flags, tsk, user_ns, fs)`;
`copy_namespaces` bate com `droid_lkm_cn_wrap(flags, tsk)`.
`check_unshare_flags` não existe como FUNC (inlined) — o wrapper testa o
ponteiro antes de chamar, então a ausência não quebra a instalação.

## 2026-11-03 — T4: offsets BTF (autoritativos no runtime)

`struct nsproxy` size=72 (3 cópias idênticas no BTF: 570, 25443, 26218):

```
+0x000 count                    +0x028 net_ns
+0x008 uts_ns                   +0x030 time_ns
+0x010 ipc_ns                   +0x038 time_ns_for_children
+0x018 mnt_ns                   +0x040 cgroup_ns
+0x020 pid_ns_for_children
```

`struct task_struct` size=4800 (campos usados):

```
+0x044 flags     +0x550 tasks    +0x618 pid      +0x628 real_parent
+0x0c0 se        +0x5a0 mm       +0x61c tgid     +0x658 group_leader
+0x680 thread_pid +0x818 real_cred +0x820 cred   +0x830 comm
+0x858 fs        +0x870 nsproxy  +0x878 signal   +0x880 sighand
```

`struct pid_namespace` size=136:

```
+0x000 idr            +0x030 child_reaper   +0x058 ucounts
+0x018 rcu            +0x038 pid_cachep     +0x060 reboot
+0x028 pid_allocated  +0x040 level          +0x068 ns
+0x048 parent         +0x050 user_ns        +0x080 memfd_noexec_scope
```

`struct ipc_namespace` size=1272:

```
+0x000 ids            +0x340 used_sems      +0x3f8 mq_set
+0x330 sem_ctls       +0x344 msg_ctlmax     +0x458 mq_sysctls
+0x3d8 mq_mnt         +0x460 ipc_set        +0x4c0 ipc_sysctls
+0x4c8 user_ns        +0x4d0 ucounts        +0x4d8 mnt_llist
+0x4e0 ns
```

`struct user_namespace` size=656: `uid_map 0`, `gid_map 0x48`,
`parent 0xd8`, `level 0xe0`, `owner 0xe4`, `ns 0xf0`.
`struct fs_struct` size=56: `users 0`, `lock 4`, `seq 8`, `umask 0xc`,
`in_exec 0x10`, `root 0x18`, `pwd 0x28`.

## 2026-11-03 — T5: headers do alvo concordam com o BTF

`~/a36-kheaders/include/linux/nsproxy.h`: count/uts_ns/ipc_ns/mnt_ns/
pid_ns_for_children/net_ns/time_ns/time_ns_for_children/cgroup_ns (mesma
ordem). `ipc_namespace.h` tem `mq_mnt` (L53), `mq_set` L65, `mq_sysctls`
L66, `ipc_set` L68, `ipc_sysctls` L69, `user_ns` L72, `ucounts` L73,
`mnt_llist` L75, `ns` L77 — mesma ordem do BTF. Logo o BTF é do kernel do
device, não de outro build.

## 2026-11-03 — T6: o módulo usa offset de runtime?

`src/main/core/ds.h:34-160`: todos os acessos a `task_struct`/`nsproxy`
passam por `droid_lkm_layout_off(...)` (offset vivo, preenchido pelo BTF).
Não há `offsetof`/`->` direto para esses campos no caminho de hook.

Exceções encontradas (acesso direto, offset de compilação) ficam em
`ipc_namespace`: `src/main/ipcns/ipcns.c` (`ns->mq_mnt`, `ns->ids`,
`ns->user_ns`, `ns->ucounts`), `ipc_mqueue.c` (`ipc_ns->mq_msg_max` etc.) e
`ipc_util.c`. Esses campos ficam antes de `mnt_llist`/`ns`, cuja ordem
difere entre GKI 6.6 puro e este build Samsung (que tem `mnt_llist`), então
os offsets acessados continuam iguais. Ainda assim: é o ponto a conferir se
o build DDK usar header GKI diferente.

## 2026-11-03 — T7: quando os hooks instalam (gating)

- `main.c`: `droid_lkm_layout_init()` → `trusted = droid_lkm_layout_trusted()`.
  Se não confiável: pidns/ipcns/slot/proc/status ficam OFF (warn), sem falhar.
- `ds_slot.c`: `create_new_namespaces` via
  `ds_hook_install_critical(...)`, e o retorno de
  `droid_lkm_nsproxy_hook_install()` é **ignorado** no `droid_lkm_slot_init`.
- `ds_hook.c`: `ds_hook_critical_missing` é setado na falha;
  `ds_hook_critical_ok()` falso.
- `main.c` (fim do init): se `!ds_hook_critical_ok() &&
  !ds_hook_degrade_enabled()` → `-EOPNOTSUPP` e o módulo recusa carregar.
  Ou seja: sem os dois hooks críticos (`create_new_namespaces` e
  `copy_namespaces`), o load falha; `degrade=1` é proibido por regra.

## 2026-11-03 — T8: build no GitHub Actions (android15-6.6)

Run `41590802923` (workflow_dispatch, ref `feat/gki-6.6-misc`), commit
`557c289`. Todos os 7 jobs da matriz verdes; `build-matrix
(android15-6.6)` em 1m38s. Gate de zero warnings passou
(`grep -nE "error:|warning:" build.log` sem match — atenção: o gate é
case-sensitive e não pega `WARNING:` maiúsculo do modpost).

Artefatos baixados para `/tmp/opencode/art/droid_lkm-android15-6.6/`:

| arquivo | bytes | sha256 |
|---|---|---|
| droid_lkm.ko | 4751800 | `1ec4c53ea38347326995297e517c3d70f9fb74619926c21f4c98e6819f61287b` |
| droid_lkm_misc.ko | 4388896 | `341d9269b7b2885a0b2abb3a06fcfe87101f22d38e9de55d4dc2bf9e05b926c3` |
| droid_lkm_vendor.ko | 1712264 | `644bd4e010916fb8c66450992995c79d6f34545379179fa3b3ab6671f0fe5b7d` |

O `.ko` já existente em `/sdcard/Download/droid_lkm-android15-6.6/` é
byte-idêntico a este artefato (mesmo sha256 `1ec4c53e…`).

## 2026-11-03 — T9: vermagic do artefato x kernel do device (BLOQUEIO)

- Artefato (`strings droid_lkm.ko | grep '^vermagic='`):
  `6.6.127-4k-g46a034eca005-dirty SMP preempt mod_unload modversions aarch64`
- Device (`a36-kheaders/include/generated/utsrelease.h` + `autoconf.h` com
  `CONFIG_SMP=1`, `CONFIG_PREEMPT=1`, `CONFIG_MODULE_UNLOAD=1`,
  `CONFIG_MODVERSIONS=1`):
  `6.6.118-android15-8-34442516-user-abA366EXXUCDZIF-4k SMP preempt mod_unload modversions aarch64`

`uname -r` do device = `6.6.118-android15-8-34442516-user-abA366EXXUCDZIF-4k`.
Logo `check_modinfo()` recusa o módulo (ENOEXEC) **antes** de qualquer hook.
`CONFIG_MODULE_FORCE_LOAD` não está setado no kernel do device
(`a36-kheaders/include/generated/autoconf.h`) e forçar é proibido por regra.
Também proibido editar a string de vermagic no `.ko`.

Registro de imagens DDK (`ghcr.io/ylarod/ddk-min`, token anônimo): 23 tags,
só duas datadas para `android15-6.6` (`20260313` e `20260828`), e ambas
apontam para o mesmo config (criado 2026-03-12, `KDIR=/opt/ddk/kdir/
android15-6.6`) que produz 6.6.127. Não existe imagem 6.6.118 publicada.

Observações que reduzem o escopo de um rebuild:
- `__versions` tem tamanho 0 (sem CRC por símbolo), então um rebuild
  contra 6.6.118 não precisa de `Module.symvers` casando CRC.
- 203 símbolos `UND` (todos precisam ser exportados pelo kernel do device);
  `create_new_namespaces`/`copy_namespaces` **não** estão entre eles — são
  resolvidos em runtime (kallsyms), não no link.
- `CONFIG_TRIM_UNUSED_KSYMS=1` no device: se algum dos 203 não for
  exportado, o load falha com `Unknown symbol` mesmo com vermagic igual.
  Só dá para verificar no device (kallsyms) ou no source Samsung.
- `CONFIG_MODULE_SIG_FORCE` não setado → assinatura não bloqueia.

## Pendente

- T10: reconstruir contra 6.6.118 (source Samsung do build A366EXXUCDZIF ou
  DDK equivalente) e repetir T8 com o vermagic correto.
- T11: no aparelho (SÓ COM AUTORIZAÇÃO): `insmod` com `degrade=0`, conferir
  `ds_hook_report` e `layout_report` em `dmesg`, e testar
  `unshare -p -i` / `clone(CLONE_NEWPID|CLONE_NEWIPC)`.
