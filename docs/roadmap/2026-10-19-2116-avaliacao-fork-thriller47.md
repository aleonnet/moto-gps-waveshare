---
status: proposto
---

# Avaliação do fork thriller47/moto-gps-waveshare (2026-10-19)

Pedido do dono: *"avalie https://github.com/thriller47/moto-gps-waveshare se ele corrige bugs do repo original
EFETIVAMENTE e se vale aproveitar algo"*. Leitura feita só em leitura (API do GitHub e clones em scratchpad, nada
executado). Base comum: `c8bdacc` do original, a mesma do nosso fork; o fork está 47 commits à frente, 0 atrás.
Quase todos os commits são do agente `google-labs-jules[bot]`.

## Conclusão

Não corrige de verdade nenhum defeito do firmware nem do app iOS do original. Não toca no caminho da tela — nada
sobre `psram_dma_direct`, `pclk_hz`, buffers, TE, PSRAM ou o erro `DMA TX underflow detected` (ver
`2026-10-19-2110-diagnostico-travamento-tela.md`). A maior parte é um app Android novo e incompleto e um
provedor de rotas OpenStreetMap com defeitos.

## O que vale aproveitar

1. Teste reforçado do rumo ausente (`ba8b9674`, `tests/native/nav_core_tests.cpp`): só teste, cobre rumo NaN e
   infinito.
2. A ideia de compilar o firmware na integração contínua (ESP-IDF 5.5.5, esp32s3), sem `sudo mv` e sem mexer no
   `.gitignore`.

## O que não aproveitar, com o motivo

- Gateway: `X-Real-IP` só com `trustProxy` (`5d051965`) — na instalação documentada atrás do Caddy todos os
  clientes passam a contar como um no limite de requisições; servidor em `0.0.0.0` (`eece00b2`, `a42d1ccd`) —
  expõe HTTP sem TLS, contra a orientação do original.
- Provedor OSM: curva com um trecho de atraso (regra do AMap aplicada ao OSRM), reserva de bicicleta
  (`routed-bike`), italiano fixo, viola `route-bundle.v1.schema.json` (`provider` só aceita `amap`), servidores
  públicos em produção; erro de busca devolvido como lista vazia (`catch {}`).
- `map_city_search: true` sem o provedor ter a função (teste alterado para acompanhar o erro).
- Textos fixos em italiano na tela redonda — superados pelo catálogo i18n e em conflito com ele.
- Remoção de 28 regras do `.gitignore` (`.env`, `*.pem`, `*.key`, `*.p8`, `sdkconfig`, binários).
- Pedidos não integrados: apagar o NVS em qualquer erro (21), desligar criptografia BLE (29, 37), zerar o
  montador BLE de outra tarefa (39).
- App Android: envia um único quadro de navegação, desvio medido contra o destino, todas as manobras viram "seguir
  em frente", fila BLE pode parar para sempre, codificador sem a mensagem de idioma `0x15`.

## Ponto em aberto que toca uma decisão nossa

O fork apagou `platforms/esp32/dependencies.lock`. A Espressif manda não versionar o lock quando há dependência
local (é o nosso caso, LVGL), mas o arquivo é hoje o único registro das versões da pilha de vídeo
(`esp_lvgl_adapter` 0.6.4, `esp_lcd_co5300`). Nesta máquina o build refaz a resolução a cada vez e sobe versões
(medido), então o lock versionado não garante reprodutibilidade aqui de qualquer forma. A decisão sobre o lock
fica para depois do diagnóstico da tela, com as versões fixadas no `idf_component.yml` se for tirado do git.

## Licença

`LICENSE.md` e `NOTICE` idênticos ao original (PolyForm Noncommercial 1.0.0, autoria "Maler X"). Reuso segue as
mesmas regras: não comercial, mantendo o `NOTICE`.
