---
status: aceito
---

# Pesquisa Glimpse (moto-gps-waveshare / maler.top) × NavBlue — app, aparelho e contrato BLE (2026-10-19)

Pedido do dono (2026-10-19): comparar como funcionam app e aparelho do Glimpse e do NavBlue, com o NavBlue como
referência, por blocos estruturais (mapas, app, firmware, BLE…), e dizer o que vale evoluir no NavBlue; depois,
comparar o contrato BLE aparelho↔app campo a campo e descrever o que e como o Glimpse envia.

**Como foi levantado:** leitura do repositório `mx3353672833-debug/moto-gps-waveshare` (branch `main`, `c8bdacc`)
pela API do GitHub, do site https://maler.top/ e do monorepo NavBlue (`/Users/alessandro/Development/navblue-monorepo`,
firmware 1.31.0 / app 1.31.0+77), com cada afirmação conferida em `arquivo:linha` pelos levantamentos. O que diz
"não levantado" ou "inferência" não foi verificado. Os números do Glimpse são o que a especificação declara; nada foi
medido em campo.

## 1. O que é o Glimpse

- Projeto de hobby de "Maler X" (maler.top é a vitrine, em chinês; contato malerxv@gmail.com). Não é vendido: o FAQ diz
  que é estudo copiando um produto estrangeiro não nomeado. Licença **PolyForm Noncommercial 1.0.0** — nada pode ser
  copiado como código para o NavBlue.
- Repositório criado em 2026-09-05, 23 commits, último de código em 2026-09-28, release única `v0.3.1-sideload`;
  453 estrelas e 77 forks (API do GitHub, 2026-10-19). Ele mesmo se declara "Experimental prototype".
- Mesma placa da nossa 175C (Waveshare ESP32-S3-Touch-AMOLED-1.75C). App só iOS (SwiftUI, iOS 17+, sem loja).
- Rota e busca pelo AMap (高德) via gateway próprio (Node/Cloudflare): cobertura da China. Mapa de fundo do aparelho:
  OSM via Protomaps, em coordenadas GCJ-02.
- Fork do dono: `aleonnet/moto-gps-waveshare`, em `~/Development/moto-gps-waveshare`; instalado na 175C e no
  iPhone XR em 2026-10-19 para avaliar a experiência (só a demo de Jinan funciona fora da China).

## 2. Tabela comparativa (NavBlue como referência)

| Bloco | NavBlue (referência) | Glimpse | Quem está à frente |
|---|---|---|---|
| Produto e negócio | Comercial: assinatura App Store/Play validada no servidor (Cloud Functions), Console de métricas, atendimento por IA, Instagram | Hobby, não vendido, licença não comercial, ~6 semanas de vida | NavBlue |
| Hardware / frota | 5 placas (175C, 175B, 206, 216, viewe) × 2 temas num único fonte; capacidade por placa detectada ao ligar | Só a 175C, sem SD/RTC/áudio; placa própria (GNSS, magnetômetro) pausada | NavBlue |
| Firmware: base | Arduino 3.3.5 (pioarduino) + LovyanGFX, C++11 | ESP-IDF 5.5.5 + LVGL 9.5, C++17 | Empate |
| Firmware: mapa | Vetor no aparelho: vias do app via BLE (protobuf) ou do cartão SD (.bin v3, z13–z15); vista de cima / atrás da moto com inclinação | Vetor no aparelho com vias **e prédios** do OSM, janela ~500 m, zoom fixo | NavBlue (Glimpse tem prédios) |
| Firmware: fluidez | Câmera desliza entre fixes, alvo 10 quadros/s, adaptativo | Interpolação a **40 Hz**, sincronizada com o sinal TE (anti-rasgo) do CO5300 | Glimpse |
| Firmware: rumo | Rumo vem do app; o IMU só acorda o aparelho | **Rumo do GPS + giroscópio** do QMI8658; congela em baixa velocidade | Glimpse |
| Firmware: HUD | Manobra, distância, velocidade, limite (com origem), ETA, nome da via, barra com paradas, curvas perigosas (CSW), radares com bipe, GPS fraco/sem fix/velho, parado, recálculo, chegada, bateria do aparelho e do celular, status com RSSI | 8 ícones de manobra, distância, arco de progresso **colorido pelo trânsito**, limite sem dados; sem ETA no aparelho, sem radar, sem curvas | NavBlue (Glimpse tem trânsito no arco) |
| Firmware: telas | Tela Inicial com relógio, AJUSTES, status, estilo simples (gratuito), 2 temas, brilho pelo toque | Navegação, velocímetro, bússola, **música (Apple Music)**; tema único, sem ajuste de brilho | NavBlue (Glimpse tem música e bússola) |
| App: plataformas | Flutter, iOS e Android, nas lojas, PT-BR/EN | iOS nativo, só por instalação manual; ~265 textos em chinês fixo, sem i18n | NavBlue |
| App: rota e busca | Valhalla **offline** por UF, Mapbox para assinantes; busca offline (SQLite FTS5) e Google Places para assinantes; recálculo, túneis, simulação | AMap online por gateway, até 3 alternativas, trânsito a cada 60 s; sem rota offline; perfil de carro | NavBlue (Glimpse tem trânsito e alternativas) |
| App: segurança na via | Curvas perigosas, radares com atualização assinada (ECDSA P-384), clima na rota | Nada disso | NavBlue |
| App: extras | Gravação de rolê (GPX), gêmeo do HUD no app (FFI) e no site (WASM), GA4 | Núcleo de navegação C++ compartilhado iOS/web (WASM) | NavBlue |
| BLE: transporte | Protobuf + cabeçalho de 4 B, blocos de 512 (MTU 515/517); V2 com CRC32 pronto no firmware, **não usado pelo app** | Binário próprio com CRC-16, ACK com reenvio, handshake com sessão, heartbeat 1 s, pareamento criptografado | Glimpse em robustez |
| BLE: sessão | Graça de 5 s, supervision 5 s, watchdog 20 s com ordem garantida em compilação, SESSION_END | Heartbeat; link morto em ~3 s; volta do segundo plano instável (problema conhecido) | NavBlue |
| Mapas: pipeline | Geofabrik → tilemaker → .bin v3; rotas e busca por UF; Brasil + EUA; R2 com sha256 | Gateway converte Protomaps em JSON z15 sob demanda; offline só do fundo | NavBlue |
| Distribuição | Instalador web (Chrome/Edge) com detecção JEDEC e pré-voo SHA-256; **sem OTA** | Só `idf.py`; sem OTA, sem binário pronto | NavBlue (OTA falta nos dois) |
| Qualidade | Milhares de testes, contraprovas por defeito plantado, ~876 quadros de referência; **sem CI** | ~94 testes; fixtures de bytes do protocolo nos dois lados; **CI no GitHub Actions** | NavBlue em profundidade, Glimpse em CI |

## 3. Recomendações para o NavBlue (ordem de valor/esforço)

1. **Ligar o protocolo BLE V2 no app.** O receptor com CRC32 já existe no firmware (`BLEManager.cpp`, caminho
   `DATA_MAGIC`/`BLETransferFrame`); falta o app enviar. Somar ACK de aplicação com reenvio só para o que não pode se
   perder (rota, SESSION_END, ALERT_BPS). Custo baixo, robustez em campo.
2. **OTA pelo app via BLE.** Nenhum dos dois tem; hoje atualizar exige computador com Chrome. Antes: medir se a tabela
   de partições (`default_16MB.csv`/board JSON de 32 MB) reserva dois slots de app (não levantado).
3. **Rumo do GPS + giroscópio.** O IMU está nas 5 placas e hoje só acorda o aparelho; estabiliza a rotação em baixa
   velocidade e em curva. Área crítica: exige replay de rolês gravados e bancada.
4. **CI** com as verificações que já existem (host, 10 envs, quadros, `flutter test`).
5. **Medir tearing e avaliar sincronia pelo TE do AMOLED** — só se aparecer em curva rápida (não medido no NavBlue).
6. **Decisões de produto, opcionais:** arco/barra colorida por trânsito para assinantes (Mapbox tem congestionamento;
   não levantado se o app já recebe), página de música e bússola, camada de prédios no mapa urbano.
7. **Atualizar a documentação** (seção 6).

## 4. Contrato BLE aparelho↔app, campo a campo

Fontes: Glimpse `shared/protocol/ble-navigation-v1.en.md` (lido inteiro); NavBlue
`navblue_esp32s3_multidevice/docs/contrato-frame-nav.md`, `src/proto/feature_info.proto` e grep em `src/ble/`.

**Resumo:** o Glimpse manda pouco (inteiros, ≤24 pontos de rota, um mapinha de ~500 m a cada ~100 m) e cada pedaço
tem integridade, sequência, ACK com reenvio, sessão, heartbeat e criptografia. O NavBlue manda mais a cada tick
(frame de 60 B + vias em protobuf + polyline com EOT) e confia só na camada de enlace.

### 4.1 Transporte (GATT)
| Item | NavBlue | Glimpse |
|---|---|---|
| Serviço | `DD3F0AD1-…` | `7e57a000-b50c-4b6a-9c57-40a54e8e1000` |
| App → aparelho | `…0AD3`, Write / WriteNR | `7e57a001`, Write / WriteNR **criptografado** |
| Aparelho → app | `…0AD2`, Indicate | `7e57a002`, Notify só com enlace criptografado |
| Segurança | **Sem pareamento nem criptografia** (grep em `src/ble/` sem ocorrência; só `PROPERTY_WRITE`/`WRITE_NR`/`INDICATE` em `BLEManager.cpp:58-63`) | LE Secure Connections + bonding "Just Works", até 3 bonds em NVS |
| Tamanho | MTU 517 (mín. 515), pedaços de 512 B (4 de cabeçalho + 508) | `min(ATT_MTU−3, peer, 512)`; usa MTU 185 → 182 B; funciona até com 20 B |
| Ritmo | Write com resposta + 5 ms entre pedaços; fila de 32 pedaços no aparelho (overflow descarta e conta), dreno 4 a cada 5 ms | WriteNR para dados, Write para controle; pedaços em série, 15 ms; respeita a contrapressão |

### 4.2 Sessão e saúde do link
| Item | NavBlue | Glimpse |
|---|---|---|
| Abertura | App pede MTU, debounce 800 ms, assina `0AD2`; aparelho manda `HUD:<W>x<H>;…` (HELLO) 3× | Handshake em 2 fases com `session_id` aleatório, versões, capacidades, tamanho de frame e intervalo de heartbeat |
| Sinal de vida | `REQ` a cada 5 s, `CRD` ~1×/s | Heartbeat 1000 ms nos dois sentidos |
| Link morto | Supervision 5 s; graça 5 s; watchdog 20 s sem frame NAV; `RST` | 3 s sem frame com CRC válido → offline e descarta remontagem |
| Recomeço | `RST` zera as 5 políticas de dedup do app e reenvia | `session_id` novo zera janela, dedup, sequência e remontagem |

### 4.3 Enquadramento
| Item | NavBlue | Glimpse |
|---|---|---|
| Cabeçalho | 4 B big-endian `0x010203xx` | 12 B LE: magic `0xB7`, versão, tipo, flags (START/END/ACK_REQ/URGENT), seq u16, offset, tamanho total |
| Integridade | Nenhuma (V2 dormente) | CRC-16/CCITT-FALSE por fragmento |
| Fim da mensagem | Frame NAV por tamanho/forma; polyline por EOT `FF FF FF FF` + `polylineLength` | START/END + offset + tamanho; remontagem até 4 KB, timeout 1 s |
| Fora de ordem / repetido | Não detecta | Rejeita buraco/sobreposição; ignora repetido; START mais novo substitui o incompleto |
| Confirmação | Só a do enlace | ACK de aplicação após decodificar e gravar; 750 ms × 2 reenvios com a mesma sequência; repetido não roda duas vezes |

### 4.4 Mensagens
| NavBlue | Glimpse | Observação |
|---|---|---|
| `0x01020301` NAV (60 B) | `0x10` NavigationSnapshot (53 B + textos) | Glimpse: quando muda, até 5 Hz; estados-chave na hora |
| `0x01020303` polyline + EOT + sufixo de janela | `0x11` RouteGeometry (≤24 pontos) | ver 4.6 |
| `0x01020302` ROAD_LAYER (vias em protobuf por tile z15) | `0x14` MapScene (vias + prédios, ~500 m) | Glimpse: a cada ~100 m, com ACK |
| `0x01020304` curvatura + paradas + estilo + época | — | só NavBlue |
| `0x01020307` ALERT_BPS (radares) | — | só NavBlue |
| — | `0x12` TrafficDeviation (≤64 trechos) | só Glimpse |
| `0x01020306` APP_STATUS (bateria do celular) | — | só NavBlue |
| — | `0x13` MediaState (título, artista, posição) | só Glimpse |
| `0x01020305` SESSION_END | `ConnectionStatus` Closing / `RouteInvalidated` | — |
| Reverso ASCII: HELLO, BAT, CRD, REQ, RST | `0x20` DeviceCommand (toque, deslize, música) com ACK; Heartbeat; Ack | Glimpse manda gestos; NavBlue manda estado do aparelho |

### 4.5 Frame NAV × NavigationSnapshot
| Dado | NavBlue (byte · tipo) | Glimpse (tipo) |
|---|---|---|
| Unidade | 0 · u8 métrico/imperial | — (sempre métrico) |
| Velocidade | 1 · u8 na unidade de exibição | `speed_deci_kph` u16 (0,1 km/h) |
| Limite | 2 · u8 + bit 6 = veio da via | `speed_limit_kph` u16 (0 = desconhecido) |
| Manobra | 3 · u8 código | `maneuver` u8 (0..12) + `maneuver_id` u32 + `roundabout_exit` |
| Progresso | 4 · u8 % + janela em base 10000 (53–58) | `route_progress_m` + `total_distance_m` u32 |
| Distância até a manobra | 5 + 7–10 · multiplicador + **texto ASCII** | `distance_to_maneuver_m` u32 |
| Restante | — | `remaining_distance_m` + `remaining_duration_s` u32 |
| ETA | 11–15 · texto "HH:MM" | calculada no aparelho a partir de `remaining_duration_s` |
| Pernas / paradas | 16–24 · até 9 % | — |
| Rumo | 25–32 · float64 | `heading_cdeg` u16 (0,01°) |
| Posição | 33–48 · lat/lon float64 | não vai no snapshot (origem da janela em E6) |
| Fonte do mapa | 6 · `mapSource` | — |
| Estado da navegação | implícito (coordenadas, bit de recálculo, SESSION_END) | `state` explícito: Idle, Acquiring, Planning, Navigating, Rerouting, Arrived |
| GPS | bit 0 fraco, bit 4 sem fix | flags HasFix, GnssStale + `accuracy_dm` |
| Fora da rota | bit 3 recálculo | flag OffRoute + `cross_track_dm` |
| Curva perigosa | bits 1–2 (grau) | — |
| Trânsito à frente | — | `traffic` u8 |
| Rede do celular | — | `network` u8 |
| Página exibida | — | `display_page` u8 |
| Nome da via | não vai no frame (vem do `road_name` das vias) | `road_name` UTF-8 ≤63 B |
| Instrução em texto | — | `instruction` UTF-8 ≤95 B |
| Identidade da rota | época no sufixo e na `0x01020304` | `route_token` (FNV-1a do id) + `route_generation` em todo snapshot |

### 4.6 Geometria
| Item | NavBlue | Glimpse |
|---|---|---|
| Rota | Polyline Google (5 casas) da janela + EOT + sufixo de bps e época; decodificada numa task própria | ≤24 pontos já recortados para a vista; 1º ponto absoluto em E6, demais em delta ZigZag/LEB128; GCJ-02 |
| Troca de janela | Janela e geometria promovidas em par; vias filtradas pela época | Staging: só substitui com token, geração, origem e contagem batendo; se não bater, **esconde a linha** |
| Vias | Protobuf `FeatureList`: tiles com x/y do tile, tipo, nome, limite, ponte/túnel, camada | ≤24 vias/192 pontos e ≤16 prédios/128 pontos, delta E6 da origem, classe |
| Tamanho e ritmo | Vias: por tile + tempo; polyline: quando o hash muda | MapScene 1,3–2,2 KB (8–14 pedaços) a cada ~100 m ou na borda |

### 4.7 O que o Glimpse envia, e como
1. Na conexão: pareia e criptografa, assina as notificações, faz o handshake em 2 fases.
2. Navegando, a cada mudança (≤5 Hz): NavigationSnapshot de ~60–200 B, sem ACK (o próximo substitui).
3. Quando a janela da rota muda: RouteGeometry (≤24 pontos).
4. Quando trânsito ou desvio mudam: TrafficDeviation.
5. A cada ~100 m: MapScene, com ACK.
6. Ocioso: heartbeat a cada 1 s.
7. No aparelho: desenho a 40 Hz interpolando entre snapshots de 5 Hz.
8. Reverso: gestos (toque, deslize, música) com ACK, sem repetição e com reenvio.

Princípio: o aparelho é um "terminal burro" de um estado já projetado para a tela, em unidades inteiras e janela
pequena; nunca recebe texto para converter (`atof`) nem a rota inteira.

### 4.8 O que serve ao NavBlue
- Integridade e sequência por pedaço: ligar o V2 (CRC32) já pronto; ACK com reenvio só para o crítico.
- Enviar menos e por mudança: recortar a polyline para a vista; distância e ETA como inteiros (m, s) — elimina o
  texto ASCII e o `atof` (origem do defeito da vírgula).
- Estado explícito no frame: fase da navegação, cross-track, saída da rotatória, nome da via.
- Heartbeat de 1 s nos dois sentidos: link morto em ~3 s, contra 5–20 s hoje.
- Pareamento criptografado: hoje qualquer central escreve no HUD — decisão de produto (muda o fluxo de conexão).

Tudo isso é protocolo app↔firmware, área crítica: exige plano com testes de contrato nos dois lados.

## 5. O que o NavBlue não tem (confirmado no código em 2026-10-19)

- OTA (nem `Update.h`/`esp_ota`/ArduinoOTA no firmware, nem DFU no app).
- Wi-Fi em uso.
- CarPlay / Android Auto.
- Música, chamadas ou notificações do celular no HUD.
- Gravação de rolê no aparelho (só no app; `NavCapture.h` é fixture de teste).
- Criptografia/pareamento BLE.
- CI (`.github/workflows` inexistente em todos os subprojetos).
- Auto-zoom na aproximação e modo noite: código presente, desligados por chave (`tuning.h`).

## 6. Documentação desatualizada do NavBlue (achada no levantamento)

| # | Afirmação no documento | O que o código diz |
|---|---|---|
| 1 | `navblue_flutter_app/README.md:3` versão 1.29.1+74 | `pubspec.yaml:19` = 1.31.0+77 |
| 2 | `navblue_flutter_app/README.md:38-39` OSRM como fallback | OSRM removido (`lib/requests/routes_requests.dart:17-20`) |
| 3 | `navblue_flutter_app/README.md:106` Nominatim | removido (`README_DEV.md:400-402`) |
| 4 | `navblue_flutter_app/README_DEV.md:1188` radares planejados | existem em `lib/alertas/` |
| 5 | `navblue_flutter_app/README_DEV.md:1095-1098` versões independentes | lockstep ordenado (`FW/CHANGELOG.md` 1.31.0) |
| 6 | `navblue_flutter_app/README_DEV.md:71` três ARBs | só `app_en.arb` e `app_pt.arb` |
| 7 | `navblue_esp32s3_multidevice/README.md:427` versão 1.23.0 | `src/app/config.h:9` = 1.31.0 |
| 8 | `navblue_esp32s3_multidevice/README.md:273` 61 testes host | 87 |
| 9 | `navblue_esp32s3_multidevice/README.md:187` só z15 lido | z13–z15 (`tuning.h:28`) |
| 10 | `navblue_esp32s3_multidevice/README.md:202` deep sleep | não encontrado no código |
| 11 | `navblue_website/README.md:14` builds em 1.27.0 | manifesto em 1.31.0 |
| 12 | `navblue_website/README.md:316-317` RTC só em 206/216 | manifesto marca também a 175B |
| 13 | `README.md` da raiz: 4 subprojetos e GitHub Pages | 6 subprojetos, Cloudflare Workers |
| 14 | `navblue_esp32s3_multidevice/README_DEV.md:179` `0AD2` como canal de envio | o app escreve na `0AD3` |

## 7. Fontes

- Glimpse: https://github.com/mx3353672833-debug/moto-gps-waveshare (README.en.md, docs/PRODUCT_SPECIFICATIONS.en.md,
  docs/KNOWN_ISSUES.en.md, docs/USER_MANUAL.en.md, shared/protocol/ble-navigation-v1.en.md,
  platforms/esp32/*, platforms/ios/*, backend/*); https://maler.top/ e https://maler.top/moto-gps/ride.html .
- NavBlue: `navblue_esp32s3_multidevice/docs/contrato-frame-nav.md`, `src/proto/feature_info.proto`,
  `src/ble/BLEManager.{h,cpp}`, `src/app/tuning.h`, READMEs, README_DEV e CHANGELOGs dos subprojetos.
- Localização do fork (pt-BR, en-US, zh-Hans) e a pesquisa de estado da arte de i18n/l10n: plano
  `/Users/alessandro/.claude/plans/compressed-skipping-kahn.md` (anexos A, B e C).
