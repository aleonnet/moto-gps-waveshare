---
status: aceito
---

# Travamento da tela redonda ao trocar o idioma — diagnóstico de causa raiz (2026-10-19)

Bancada do dono na Waveshare 1.75C (ESP32-S3, painel CO5300 466×466, octal PSRAM), firmware do ramo `feat/i18n`.
Sintoma relatado: ao trocar o idioma no app, a tela redonda muda o título ("MOTO GPS / PRONTO", "PRONTO PARA
RODAR"), a linha de baixo fica em inglês ("Choose a destination on the phone") e a tela para de responder.

## Correção do que eu disse antes

Às ~20h50 afirmei "causa provada: a gravação do idioma na flash coincide com a transferência da tela". **Errado:**
era correlação. Gravei um conserto apoiado nisso (esperar a tela parada, com a trava, antes de gravar) e o defeito
continuou — a medição refutou a hipótese (fato 4). Às ~21h05 escrevi também que nesta placa nunca há
transferência fora da trava; **errado** de novo — conferido no adaptador, o envio é assíncrono (fato 4). O
conserto está no diretório de trabalho, sem commit (seção "O que desfazer").

## Fatos medidos (log serial, três trocas de idioma, três firmwares)

| Captura | Evento | Linhas do log |
|---|---|---|
| firmware i18n original | troca de idioma | `E spi_master: DMA TX underflow detected` → `E (376950) lcd_panel.io.spi: panel_io_spi_tx_param(222): recycle spi transactions failed` → `E (376955) esp_lvgl:bridge_v9: Draw bitmap failed: ESP_ERR_INVALID_STATE` |
| diagnóstico (log da gravação) | troca para en-US | `I (11286) storing display language en-US` · `I (11289) display language stored in 2504 us` · underflow · `E (11299) … recycle spi transactions failed` |
| "conserto" (grava com a trava e tela parada) | troca para pt-BR | `I (223873) display language pt-BR stored` · underflow · `E (223903) … recycle spi transactions failed` |

- Nas três: depois do erro, o relatório `display perf` (a cada 5 s) some para sempre; o Bluetooth continua
  (`GATT procedure initiated: notify` segue). A tela parou; a placa não.
- Nas quatro conexões do app registradas (o app reenvia o idioma atual a cada conexão, sem gravação porque é o
  mesmo idioma) não houve erro: `iPhone connected` em 4196, 4220, 218437 e 366883 ms.
- Boot: `internal heap: free 45 KiB, minimum 7 KiB` e `ble_store_config_write_local_irk rc=27` /
  `Failed to persist local IRK (rc=17)` — anteriores a esta frente, registrados como risco.

Logs completos (scratchpad da sessão): `serial-repro2.log`, `serial-diag.log`, `serial-fix.log`.

## Fatos do código (lido no ato, ESP-IDF 5.5.5 instalado, componentes gerenciados do projeto)

1. **O erro é falta de dados na transferência da tela a partir da PSRAM.** `spi_master.c:963`
   (`spi_trans_dma_error_check`) só emite `DMA TX underflow detected` quando o buffer de envio está na PSRAM e o
   SPI esvaziou; a checagem roda no fim da transação.
2. **Um único erro trava a tela para sempre — defeito do driver do painel.** `spi_device_get_trans_result`
   (`spi_master.c`) retira o resultado da fila e devolve `ESP_ERR_INVALID_STATE` se a transação teve underflow.
   `panel_io_spi_tx_param` (`esp_lcd_panel_io_spi.c:217-222` no 5.5.5) sai por `ESP_GOTO_ON_ERROR` **sem
   decrementar `num_trans_inflight`**; na chamada seguinte espera com `portMAX_DELAY` um resultado que já saiu da
   fila. O mesmo trecho está igual no `master` do ESP-IDF hoje (`curl` do arquivo, linhas 219-225).
3. **A placa usa leitura direta da PSRAM pelo DMA** (`board_port_waveshare_1_75c.cpp:252`,
   `io_config.flags.psram_dma_direct = true`), descrita no ESP-IDF como *"has speed limit"*
   (`esp_lcd_io_spi.h:41`). Buffers de 466×320 em PSRAM (`kDrawBufferHeight = 320`), uma transação de até
   298.240 bytes, `pclk_hz = 40 MHz` QSPI, PSRAM 80 MHz, fila de profundidade 1.
4. **O envio é assíncrono, e a gravação simultânea foi refutada por medição.** A placa usa
   `tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE` (`board_port_waveshare_1_75c.cpp:886`) e faz a
   sincronia com o TE no seu próprio evento `LV_EVENT_FLUSH_START`; o adaptador vai para
   `display_bridge_v9_flush_default`, que dispara `esp_lcd_panel_draw_bitmap` e volta, e o fim chega pela
   interrupção (`display_bridge_v9_handle_vsync`, `lvgl_bridge_v9.c:1837-1850`, `flush_ready`). O firmware do
   "conserto" esperou `flushing == 0` com a trava antes de gravar; o log não tem o aviso `panel busy`, então a
   gravação não coincidiu com transferência — e a transferência seguinte falhou do mesmo jeito.
5. **A gravação na flash não desliga o cache.** `spi_flash_os_func_app.c:29`: com `SPIRAM_FETCH_INSTRUCTIONS` e
   `SPIRAM_RODATA` ligados (são, `sdkconfig`), `SPI_FLASH_CACHE_NO_DISABLE` vale e `spi1_start` só pega um mutex.
   A limpeza de cache pós-escrita (`flash_mmap.c:318`) só atinge páginas mapeadas; a partição NVS não é.
6. **Trocar para o mesmo idioma também redesenha** (`lv_translation.c:130-135`, sem retorno antecipado), e
   isso acontece a cada conexão sem erro (fatos medidos acima).

## Corroboração externa (fonte primária)

[espressif/esp-idf#18764](https://github.com/espressif/esp-idf/issues/18764) (IDF 5.5.4, ESP32-S3, painel
466×466 da família SH8601/CO5300, `psram_dma_direct = true`): a mesma sequência
`DMA TX underflow detected` → `recycle spi transactions failed` → LVGL preso em `wait_for_flushing`. O autor
mediu que baixar o PCLK para 40 MHz e partir as transações em ~15 KB **não muda nada**, e que
`psram_dma_direct = false` **elimina** o erro. Resposta da Espressif: *"It appears to be an MSPI bandwidth issue.
40 MHz may still be too high. You could try further reducing the PCLK, increasing the PSRAM frequency, and
enabling PSRAM XIP."* Fechada por inatividade, sem correção no driver.

## Como o NavBlue evita isso na mesma placa (lido no ato)

`navblue_esp32s3_multidevice` roda na mesma 1.75C (`src/app/boards/board_175C.h`, CO5300 QSPI 40 MHz,
`src/app/lgfx_device.hpp:365-373`) com LovyanGFX 1.2.25 e grava preferências no NVS em uso
(`src/ui/UiPrefsStore.h`). A LovyanGFX **nunca manda o DMA ler direto da PSRAM**: `Bus_SPI::writePixels`
(`Bus_SPI.cpp:569-583` da 1.2.25) copia os pixels em pedaços para um `FlipBuffer` de dois buffers em RAM interna
de DMA (`common.hpp`: `heap_alloc_dma` = `heap_caps_malloc(..., MALLOC_CAP_DMA)`), reservados de antemão
(*"makes steady-state getBuffer() calls allocation-free, so transient heap starvation cannot fail them
mid-draw"*), e só então dispara o DMA. É o mesmo princípio que eliminou o erro em #18764
(`psram_dma_direct = false`).

## Causa raiz

- **Raiz (projeto original, anterior a esta frente):** o caminho de envio da tela lê o quadro direto da PSRAM
  pelo DMA, sem folga de banda no barramento de memória compartilhado (MSPI). Qualquer pico de disputa nesse
  barramento durante uma transferência esvazia o SPI. Inferência apoiada nos fatos 1 e 3 e no caso #18764.
- **Agravante (ESP-IDF):** o driver do painel não se recupera de um único underflow (fato 2) — a tela trava
  para sempre em vez de perder um quadro.
- **Gatilho observado:** a troca de idioma (3 de 3 trocas, 0 de 4 conexões). **Não está provado** qual
  atividade daquela transferência provoca o pico. Descartado: gravação simultânea à transferência
  (medido, fato 4); cache desligado durante a gravação (lido, fato 5). Sobram: (a) a gravação ainda assim pesar no barramento
  logo depois; (b) o quadro pós-troca ser maior (as três linhas mudam de tamanho; pode ocupar as duas faixas de
  320 linhas) e/ou executar código frio da PSRAM; (c) os dois juntos.

## Medição que falta (diagnóstico, não conserto) — aguarda o dono

Um firmware de diagnóstico, sem mudar comportamento, que registra por quadro a área enviada (linhas, bytes) no
evento `LV_EVENT_FLUSH_START` que a placa já observa, durante os 2 s seguintes a uma troca, e:

- E1 — troca de idioma **sem gravar** (gravação desligada só nesse firmware): se travar, a gravação não é
  necessária (gatilho = o quadro da troca).
- E2 — gravação **sem troca** (a mesma gravação repetida a cada 2 s na tela "PRONTO PARA RODAR"): se travar, a
  gravação basta.

## Pesquisa de boas práticas e medições publicadas (2026-10-19, notas em scratchpad `research-lcd/`)

- Espressif, FAQ de LCD: *"Use PSRAM as a framebuffer, and then use a small SRAM buffer to transfer data ... in
  multiple batches."* (https://docs.espressif.com/projects/esp-faq/en/latest/software-framework/peripherals/lcd.html)
- ESP-IDF, guia RGB (`rgb_lcd.rst:158`): buffers de "bounce" em SRAM são *"more robust against short bandwidth
  spikes"*; `:68`: CPU e EDMA dividem a banda da PSRAM.
- ESP-IDF `external-ram.rst:222`: *"The bandwidth that DMA accesses external RAM is very limited, especially when
  the core is trying to access the external RAM at the same time."*
- Medição publicada (exemplo `qspi_without_ram` do ST77903, 400×400, ESP32-S3R8): buffer de 100 linhas em SRAM
  interna = 30 fps; buffer de quadro em PSRAM = 25 fps. O driver dele copia da PSRAM para buffers internos antes
  do DMA (*"data in PSRAM can't be transmitted by SPI DMA currently"*).
- `psram_dma_direct` entrou no ESP-IDF em 2025-07 (`7538b519ea`, *"GPSPI transfer bandwidth should be less than
  PSRAM bandwidth, otherwise transmission data may be lost"*), virou padrão em 2026-02 e a Espressif o tornou
  opcional de novo em 2026-04 (`36658b2104`, *"has speed limit"*).
- LVGL/esp_lvgl_port: buffer ≥ 1/10 da tela; >25% não melhora; buffers pequenos em SRAM interna < 10% da tela
  (o que caberia nos 45 KiB livres) têm efeito severo — descartado.
- PSRAM a 120 MHz nesta placa: experimental, exige flash 120 MHz e tem risco acima de 65 °C — descartado (moto ao
  sol).
- Conferido no ESP-IDF 5.5.5 instalado: cada transação de cor tem no máximo 32.768 bytes
  (`SPI_LL_DMA_MAX_BIT_LEN = 1<<18`, `spi_bus_get_max_transaction_len`); sem `psram_dma_direct` o driver aloca um
  temporário interno do tamanho do pedaço e copia (`setup_dma_priv_buffer`); falta de memória perde uma faixa
  (`ESP_ERR_NO_MEM`), não trava; `CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL=32768` já reserva 32 KB internos para DMA.
  O comentário em `board_port_waveshare_1_75c.cpp:248-251` ("same-sized internal bounce buffer") é impreciso: o
  temporário é por pedaço (≤ 32 KB).
- Fila de profundidade 1 (`CONFIG_BSP_LCD_TRANS_QUEUE_DEPTH=1`): cada pedaço espera o anterior
  (`esp_lcd_panel_io_spi.c:364-373`), então o envio de uma faixa de 320 linhas segura o LVGL ~14 ms (conta, a
  confirmar com o log `display flush cb`).

## Caminhos de conserto (para decidir depois da medição)

1. **Recomendado:** o caminho do NavBlue — o DMA lê de buffers pequenos em RAM interna, pré-reservados, e a CPU
   copia a imagem da PSRAM para eles em pedaços (no `esp_lcd`: `psram_dma_direct = false` com transações
   pequenas, ou buffers de desenho menores em RAM interna). É o que eliminou o erro em #18764. Custo a medir: RAM interna (hoje 45 KiB livres, mínimo 7 KiB) e quadros por
   segundo. O comentário em `board_port_waveshare_1_75c.cpp:248-251` diz que a cópia do buffer **inteiro** já
   falhou com o NimBLE ativo; a diferença é o tamanho do pedaço.
2. Sugestões da Espressif: PCLK menor (perde quadros por segundo), PSRAM mais rápida (120 MHz é restrito a
   certos chips), XIP (já está ligado).
3. Recuperação do erro (fato 2): exige corrigir o driver do ESP-IDF — fora do projeto; reportar à Espressif.

## O que desfazer

`board_port_wait_panel_idle` (`board_port.h`, `board_port_waveshare_1_75c.cpp`), a gravação sob a trava em
`phone_nav_bridge.cpp`, a constante `kPanelIdleTimeoutMs` e os testes/substitutos correspondentes em
`tests/native` — a hipótese foi refutada (fato 4); decidir depois de E1/E2 se uma proteção da gravação ainda
se justifica por medição. O teste novo da tela "PRONTO PARA RODAR" em
`nav_ui_render_tests.cpp` fica: ele cobre o cenário que faltava. A linha de log
`display language … stored` fica (é o que tornou o diagnóstico possível).

## Riscos que já existiam (fora desta frente)

Gravação de pareamento do NimBLE e reparo do NVS na partida também gravam flash com a tela ativa; o NimBLE falha
ao gravar a IRK na partida (`rc=27`). Medir depois de E1/E2.

## Resultado na bancada (2026-10-19, ~22h)

Conserto aplicado em `board_port_waveshare_1_75c.cpp`: `psram_dma_direct = false`, pedaços de 12.276 bytes
(`kPanelChunkBytes`: o barramento arredonda `max_transfer_sz` para descritores inteiros de 4.092 bytes,
`spicommon_dma_desc_alloc` — o firmware medido pediu 9.320 e já recebeu 12.276) e fila de 2 transações
(`kPanelQueueDepth`); log novo `internal DMA heap`. Medido
com o celular conectado, mesmo roteiro nos dois firmwares (logs `serial-a0.log` e `serial-a1.log` no scratchpad):

| | Antes (referência) | Com o conserto |
|---|---|---|
| Trocas de idioma | 1 de 1 travou (e 3 de 3 nas rodadas anteriores) | 16 de 16 sem erro; 0 `underflow`, 0 `Failed to allocate` |
| Tela "PRONTO PARA RODAR" | 25,0 fps, render 18,1/26,3 ms | 25,0 fps, render 17,6–20,3 ms |
| Envio ao painel (`display flush cb`) | 5,7 ms por envio | 4,8 ms por envio |
| Navegação de demonstração (mapa) | não medida (o mapa não chegou à tela nessa rodada) | 13–16 fps, render 54–71 ms (o desenho domina) |
| RAM interna de DMA | livre 38 KiB, maior bloco 20 KiB | livre 25 KiB, maior bloco 17 KiB (8 KiB no mapa, com 2 temporários vivos) |

Pendências: comparar o mapa com o firmware antigo; medição longa da RAM interna de DMA, olhando o mínimo com o
celular reconectando — as duas cópias (até 24.552 bytes) ficam alocadas até o próximo envio. Se uma cópia de 12.276
bytes não achar bloco livre, a tela **não trava** (`ESP_ERR_NO_MEM` antes da fila, `num_trans_inflight` intacto,
`flush_ready` chamado), mas o resto daquela área não é enviado e, por inferência do revisor (não medido), o próximo
envio pode sair com lixo porque o último pedaço na fila mantinha o CS ativo (`SPI_TRANS_CS_KEEP_ACTIVE`). Se a folga
não bastar, buffers de transferência reservados no boot (o caminho do NavBlue/LovyanGFX).
