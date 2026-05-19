# network/ — WireGuard tunnel for cross-PC measurement

`comm_benchmark` 의 a↔d 측정을 위해 b↔c 사이에 WireGuard 터널을 깐다.
GRE 로 시도했으나 UDP 가 NM Shared / 사내 정책의 어딘가에서 protocol
discriminate 되어 흘러가지 못해 WG (UDP 51820 단일 포트) 로 전환.

## Topology

```
PC a (10.42.0.141)
   └── 직결 (10.42.0.0/24)
        └── PC b (10.42.0.1 + 10.222.68.241)
              └── corp + WG/UDP 51820
                    └── PC c (12.56.52.76 + 10.42.2.1)
                          └── 직결 (10.42.2.0/24)
                                └── PC d (10.42.2.110)
```

터널 내부 (b↔c):
- b: `10.99.0.1/30`
- c: `10.99.0.2/30`

## TL;DR — `setup_wg.sh` 한 파일로 (권장)

PC당 2번 실행, 총 4 명령. 키 생성/설치/적용 다 묶여있음.

```bash
# PC b (1차)
bash setup_wg.sh b
# → 화면에 b 의 pubkey 출력. 복사.

# PC c (1차)
bash setup_wg.sh c
# → 화면에 c 의 pubkey 출력. 복사.

# PC b (2차) — c 의 pubkey 인자로
bash setup_wg.sh b <c-pubkey>

# PC c (2차) — b 의 pubkey 인자로
bash setup_wg.sh c <b-pubkey>
```

각 2차 실행이 conf 작성 + `wg-quick up wg0` + `wg show` 까지 자동.
`latest handshake: ... seconds ago` 보이면 성공.

아래는 수동으로 가고 싶을 때의 디테일.

## 사전 준비 (PC b, c 각각)

```bash
sudo apt install -y wireguard
sudo mkdir -p /etc/wireguard && cd /etc/wireguard

# PC b
sudo sh -c 'wg genkey | tee b_priv | wg pubkey > b_pub'
sudo cat b_pub

# PC c
sudo sh -c 'wg genkey | tee c_priv | wg pubkey > c_pub'
sudo cat c_pub
```

각 PC 의 `_pub` 출력은 **정확히 44자 (마지막 `=` 포함)** 이어야 한다.
짧게 잘리면 handshake 실패의 원인.

## Pubkey 교환

본 디렉토리의 `wg0.b.conf` / `wg0.c.conf` 에 상대방 pubkey 가 이미
기입되어 있다 (2026-05-13 사용자 제공값). 다른 키 쌍을 새로 생성한다면
두 conf 의 `[Peer] PublicKey =` 줄을 갱신해야 한다.

## 적용

```bash
# PC b
cd <colcon_ws>/src/comm_benchmark/network
bash apply_wg.sh b

# PC c
cd <colcon_ws>/src/comm_benchmark/network
bash apply_wg.sh c
```

스크립트가 하는 일:
1. `wg0.<host>.conf` 를 `/etc/wireguard/wg0.conf` 로 복사
2. 자리표시자 `__PASTE_<HOST>_PRIV_HERE__` 를 `/etc/wireguard/<host>_priv`
   값으로 치환
3. `chmod 600`
4. `sudo wg-quick up wg0`
5. `sudo wg show` 출력 (handshake 확인용)

## 검증

```bash
# PC b
sudo wg show wg0
# → "latest handshake: N seconds ago" 가 보여야 정상
# → "transfer: 0 B received" 만 보이면 키 또는 reachability 문제

# PC a
ping -c 3 10.42.2.110
traceroute -n 10.42.2.110
# → 3 hop: 10.42.0.1 → 10.99.0.2 → 10.42.2.110
```

UDP 데이터플레인 검증:

```bash
# PC a
sudo tcpdump -ni any 'udp port 18000'

# PC d
echo "wgtest" | nc -uw1 10.42.0.141 18000
# → PC a tcpdump 에 패킷 한 줄 보여야 OK
```

## 해제

```bash
# PC b
sudo wg-quick down wg0

# PC c
sudo wg-quick down wg0
```

재부팅하면 자동 해제 (휘발성). 부팅시 자동 활성화하고 싶으면:
```bash
sudo systemctl enable wg-quick@wg0
```

## PC c 모드 스위치 — `pc_c_mode.sh`

PC c 가 두 벤치 시나리오에 동시에 등장 (e/f clean-LAN + a↔d WG) 하고,
둘 다 `10.42.0.0/24` 를 쓰기 때문에 라우팅이 충돌. 모드 스위치 한 줄로
전환:

```bash
# a↔d 벤치 (zenoh_router 등) 측정 시작 전
bash network/pc_c_mode.sh abcd

# 끝나고 e/f clean-LAN 으로 돌아갈 때
bash network/pc_c_mode.sh clean_lan

# 현재 상태만 확인
bash network/pc_c_mode.sh status
```

스크립트가 하는 일:

- **abcd 모드**: hub-facing NM 연결 (`eno3np0`) down → 그 위의 connected
  route 가 wg0 경로를 shadowing 하던 문제 해소 → `10.42.0.0/24 via
  10.99.0.1 dev wg0` 추가 → `ip_forward=1` 보장.
- **clean_lan 모드**: wg0 경로 제거 → hub NM 연결 up → NM 의
  `noprefixroute` 함정 (auto connected route 누락) 시 connected route 수동
  재추가.
- WG 터널 자체 (`wg0`) 는 양 모드 모두 살아있음 — 다시 띄울 필요 없음.

기본 가정 (env 로 override 가능):
- `HUB_IFACE=eno3np0` — e/f 가 붙은 iptime 허브 쪽 iface
- `WG_IFACE=wg0`
- `WG_GATEWAY=10.99.0.1` — b 의 WG IP

## Troubleshooting

| 증상 | 원인 | 조치 |
|------|------|------|
| `wg show` 에 "latest handshake" 안 뜸 | peer pubkey 오타 또는 c→b 또는 b→c reachability | b 에서 `nc -uvw3 12.56.52.76 51820`, c 에서 동일 역방향 |
| handshake 됐는데 ping 안 됨 | FORWARD 룰 미적용 | `iptables -nvL FORWARD \| grep wg0` — `wg0` 포함 룰 없으면 conf 의 PostUp 가 실패한 것 |
| ping 됨, raw_udp 0 rows | a 또는 d 의 listener 미바인딩 | `ss -ulpn \| grep 1800` 으로 확인 |
| corp 이 UDP 51820 차단 | DPI 또는 outbound block | 다른 ListenPort (예: 443) 로 변경 |
