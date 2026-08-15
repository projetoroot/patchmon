# patchmon
Ajustes e Configurações para o software.

Scripts de auto-enroll

Para funcionar de maneira automática tanto o LXC como para VM, é necessário colocar na Cron conforme o exemplo:

root@pve:~# cat /etc/crontab 

...

*/5 * * * * root /root/patchmon_lxc_autoenroll_cron.sh

*/5 * * * * root /root/patchmon_vm_autoenroll_cron.sh

...


# Comparação: Auto-Enrollment Oficial do PatchMon vs Script Proxmox do Projeto Root

| Característica | Script oficial do PatchMon | Script Proxmox personalizado |
|---|---|---|
| **Auto-Enrollment** | ✅ Sim | ✅ Sim |
| **Instalação automática do Agent** | ✅ Sim | ✅ Sim |
| **Descoberta automática de LXC** | ✅ Sim, no fluxo Proxmox LXC oficial | ✅ Sim |
| **Descoberta automática de VMs** | ❌ Não é o foco | ✅ Sim |
| **Integração com Proxmox** | ✅ Para LXC | ✅ LXC + VM |
| **Uso de `pct`** | ✅ | ✅ |
| **Uso de `qm`** | ❌ | ✅ |
| **Uso do QEMU Guest Agent** | ❌ Não é o foco do script LXC | ✅ Sim |
| **Execução dentro do LXC** | ✅ | ✅ `pct exec` |
| **Execução dentro da VM** | ❌ | ✅ `qm guest exec` |
| **Detecta VMID/CTID** | ⚠️ Não como principal mecanismo de identificação | ✅ Sim |
| **Detecta hostname** | ✅ | ✅ |
| **Detecta IP** | ✅ | ✅ |
| **Detecta arquitetura** | ✅ | ✅ |
| **Detecta SO(Windows)** | ❌ Não é o foco do script | ✅ |
| **Detecta Machine ID** | ✅ | ✅ |
| **Detecta Proxmox Node** | ⚠️ Limitado | ✅ |
| **Friendly Name personalizado** | ✅ Prefixo/configuração oficial | ✅ Totalmente personalizado |
| **Friendly Name LXC** | Exemplo: `prod-web` | `CT-214-web` |
| **Friendly Name VM** | Não aplicável ao script LXC | `VM-104-Debian` |
| **Instala `curl`** | ✅ Pelo instalador | ✅ Verificado antes |
| **Instala `cron`** | ⚠️ Não é o foco | ✅ LXC |
| **Instala `procps`** | ⚠️ Depende do sistema | ✅ LXC |
| **Verifica `pgrep`** | Depende do instalador | ✅ |
| **Detecta `systemd`** | ✅ | ✅ |
| **Suporte a OpenRC** | Depende da distribuição | ✅ |
| **Suporte a Supervisor** | Não é o foco principal | ✅ |
| **LXC sem systemd** | ⚠️ Pode apresentar limitações | ✅ Tratado |
| **Inicialização manual do Agent** | ❌ Não é o foco | ✅ |
| **Wrapper para Agent** | ❌ | ✅ |
| **Verifica se Agent já está instalado** | ✅ | ✅ |
| **Verifica se Agent está executando** | ✅/depende do fluxo | ✅ |
| **Testa `patchmon-agent ping`** | ✅ | ✅ |
| **Reinicia Agent parado** | Depende do sistema | ✅ |
| **Evita reinstalação desnecessária** | ✅ | ✅ |
| **Tratamento de HTTP 409** | Conforme implementação oficial | ✅ |
| **Log centralizado no Proxmox** | ❌ | ✅ |
| **Execução via cron** | ✅ Pode ser configurada | ✅ |
| **Execução periódica para novos LXC** | ✅ | ✅ |
| **Execução periódica para novas VMs** | ❌ | ✅ |
| **Controle centralizado pelo Proxmox** | ⚠️ Parcial | ✅ |
| **Suporte específico a ambiente Proxmox** | ✅ LXC | ✅ LXC + VM |
| **Complexidade** | 🟢 Baixa | 🟡 Média |
| **Personalização** | 🟡 Média | 🟢 Alta |
| **Controle operacional** | 🟡 Médio | 🟢 Alto |
| **Portabilidade** | 🟢 Alta | 🔴 Baixa |
| **Manutenção do código** | 🟢 Baixa | 🟡 Maior |
| **Dependência do Proxmox** | 🟡 Parcial | 🔴 Alta |
| **Compatibilidade futura com PatchMon** | 🟢 Melhor | 🟡 Requer acompanhamento |
| **Compatibilidade futura com Proxmox** | 🟢 Não depende diretamente | 🟡 Requer acompanhamento |
| **Adequado para poucos hosts** | ✅ Excelente | ✅ |
| **Adequado para muitos LXC** | ✅ | ✅ Excelente |
| **Adequado para muitas VMs** | ⚠️ Requer automação adicional | ✅ Excelente |
| **Adequado para ambiente altamente personalizado** | 🟡 | ✅ Excelente |

---

## Principais vantagens do script oficial

| Ponto | Descrição |
|---|---|
| **Manutenção** | É mantido pelo projeto PatchMon |
| **Compatibilidade** | Acompanha a implementação oficial do Agent e Auto-Enrollment |
| **Simplicidade** | Menos código e menos componentes |
| **Portabilidade** | Não depende diretamente da estrutura interna do Proxmox |
| **Atualizações** | Menor necessidade de alterações locais |
| **Dry Run** | Disponível no fluxo oficial |
| **Force Install** | Disponível no fluxo oficial |
| **Documentação** | É o método recomendado pela documentação do PatchMon |

---

## Principais vantagens do script Projeto Root

| Ponto | Descrição |
|---|---|
| **Descoberta automática** | Detecta LXC e VMs diretamente no Proxmox |
| **VMID/CTID** | Usa o ID do recurso como parte da identificação |
| **Friendly Name** | Padroniza nomes como `CT-214-web` e `VM-104-Debian` |
| **Dependências** | Pode preparar automaticamente `curl`, `cron` e `procps` |
| **Recuperação** | Pode detectar e iniciar Agent parado |
| **LXC sem systemd** | Possui tratamento específico |
| **VMs** | Usa QEMU Guest Agent para administrar VMs |
| **Centralização** | Um único nó Proxmox pode administrar o processo |
| **Automação** | Adequado para execução periódica |
| **Customização** | O comportamento pode ser adaptado ao ambiente |

---

## Principais desvantagens do script oficial

| Ponto | Impacto |
|---|---|
| **Menor integração com Proxmox** | Não administra diretamente todos os recursos do host |
| **VMs** | O fluxo oficial de LXC não resolve automaticamente o gerenciamento das VMs |
| **Customização** | Menor liberdade para adaptar o comportamento |
| **Friendly Name** | Menos específico para a estrutura Proxmox |
| **LXC especiais** | Containers sem systemd podem exigir tratamento adicional |
| **Recuperação** | Depende mais da configuração do sistema operacional |

---

## Principais desvantagens do script Projeto Root

| Ponto | Impacto |
|---|---|
| **Manutenção própria** | O script precisa ser acompanhado |
| **Mudanças na API** | Alterações futuras do PatchMon podem exigir ajustes |
| **Mudanças no Proxmox** | Alterações em `pct`, `qm` ou QEMU Guest Agent podem exigir ajustes |
| **Complexidade** | Mais código e mais cenários para tratar |
| **Dependência do Proxmox** | Não é uma solução portátil |
| **Segurança** | As credenciais de Auto-Enrollment precisam ser protegidas no Proxmox |
| **Testes** | Novas versões do PatchMon devem ser validadas |

---

## Fluxo do script oficial

```text
Sistema operacional
        |
        v
Instalador PatchMon
        |
        v
Auto-Enrollment
        |
        v
PatchMon
        |
        v
PatchMon Agent
```
---

## Fluxo do script Projeto Root

```text
                           PROXMOX
                              |
                    +---------+---------+
                    |                   |
                   LXC                 VM
                    |                   |
                 pct list            qm list
                    |                   |
                    v                   v
              Identifica CT        Identifica VM
                    |                   |
                    +---------+---------+
                              |
                              v
                     Recurso está ativo?
                              |
                    +---------+---------+
                    |                   |
                   NÃO                 SIM
                    |                   |
                  Ignora                v
                                Verifica acesso
                              +---------+---------+
                              |                   |
                           Falha               Sucesso
                              |                   |
                            Loga                  v
                                              Coleta dados
                                                  |
                                +-----------------+-----------------+
                                |                 |                 |
                            Hostname              IP           Machine ID
                                |                 |                 |
                                +-----------------+-----------------+
                                                  |
                                                  v
                                          Detecta arquitetura
                                                  |
                                                  v
                                        Verifica PatchMon Agent
                                                  |
                                  +---------------+---------------+
                                  |                               |
                               Instalado                      Não instalado
                                  |                               |
                                  v                               v
                         Agent está executando?          Verifica dependências
                                  |                               |
                       +----------+----------+            +-------+-------+
                       |                     |            |       |       |
                      SIM                   NÃO         curl    cron    procps
                       |                     |            |       |       |
                       v                     v            +-------+-------+
                 Executa ping           Inicia Agent              |
                       |                     |                    v
                       |                     |             Auto-Enrollment
                       |                     |                    |
                       |                     |                    v
                       |                     |             Recebe API ID
                       |                     |             + API Key
                       |                     |                    |
                       |                     |                    v
                       |                     |             Instala Agent
                       |                     |                    |
                       |                     |                    v
                       |                     |             Verifica instalação
                       |                     |                    |
                       +-----------+---------+--------------------+
                                   |
                                   v
                            Agent está ativo?
                                   |
                          +--------+--------+
                          |                 |
                         NÃO               SIM
                          |                 |
                          v                 v
                        Loga          Testa comunicação
                                            |
                                   +--------+--------+
                                   |                 |
                                  Falha             OK
                                   |                 |
                                   v                 v
                           Tenta recuperação     Host operacional
                                   |                 |
                                   +--------+--------+
                                            |
                                            v
                                       PatchMon
