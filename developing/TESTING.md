# RemoteIMESync 테스트 절차

현재 상태: **호스트 스모크 테스트만 통과**(F18 트리거 + anyApp 모드). Jump 를 낀
클라이언트 실기기 테스트는 아직 한 번도 안 했다.

## 왜 그냥 Cmd+Space 로는 테스트가 안 되나

앱 v0.1 은 "트리거 키 = 호스트 토글 키" 전제다 — 이벤트를 **그대로 통과**시켜서
호스트의 심볼릭 핫키가 반응하게 한다. 그런데 2026-08-25 에 호스트 토글 키를
`Cmd+Space` → **`⌃⌥⌘Space`** 로 바꿨다(뷰어 탭 타임아웃 누수 회피). 그래서 앱이
Cmd+Space 를 통과시켜도 호스트는 아무 반응을 안 한다.

→ **테스트는 트리거를 `⌃⌥⌘Space` 로 맞춰서** 한다. 누르는 키가 어색한 건 감수한다.
Cmd+Space 로 누르고 ⌃⌥⌘Space 로 내보내는 것(=`sendAs`)이 v0.2 의 핵심 미구현분이고,
그건 이 테스트가 통과한 뒤에 붙인다.

## 클라이언트 실기기 테스트 (맥북)

1. **바이너리 전달** — 호스트에서 유니버설(인텔+애플실리콘) 빌드:
   ```sh
   swift build -c release --arch x86_64 --arch arm64 --product RemoteIMESync
   # .build/apple/Products/Release/RemoteIMESync  → AirDrop 또는 scp 로 맥북 ~/.local/bin/
   ```

2. **Karabiner 한영 sync 룰 끄기** (동시 실행 = 이중 토글).
   Karabiner Settings > Complex Modifications 에서 "Jump Desktop 한영 sync (client)" 룰만
   Remove. 나머지 룰(Caps 레이어·스왑 등)은 그대로 둔다.

3. **테스트 config** — 트리거를 호스트 토글 키와 일치시킨다:
   ```sh
   mkdir -p ~/.config/remote-ime-sync
   cat > ~/.config/remote-ime-sync/config.json <<'EOF'
   { "triggerKeyCode": 49,
     "triggerModifiers": ["command", "control", "option"] }
   EOF
   ```
   (49 = spacebar. `bundlePrefixes` 기본값 `com.p5sys.jump` 라 Jump 앞에 있을 때만 동작.
   앱 밖에서 단독 확인하려면 `"anyApp": true` 추가.)

4. **실행** — 첫 실행은 터미널에서 (로그를 봐야 함):
   ```sh
   ~/.local/bin/RemoteIMESync
   ```
   `could not create event tap` 이 뜨면 시스템 설정 > 개인정보 보호 > **입력 모니터링**에
   그 바이너리를 추가하고 다시 실행. 성공하면 메뉴바에 `⇄한` 이 뜬다.

5. **확인** — Jump 로 호스트 접속 후, Jump 창이 앞에 있는 상태에서:

   | 키 | 기대 |
   |---|---|
   | `⌃⌥⌘Space` | 클라·호스트 양쪽 전환. 로그에 `local -> ...` |
   | `⌃⌥⌘⇧Space` | 호스트만 전환(재정렬), 로그에 `realign: host-only toggle` |

   진짜 봐야 할 것: **영→한 전환 직후 곧바로 한글이 찍히는가** (500ms 포커스 블립이
   Jump 뷰어에서 먹는지). 자소가 깨지거나 첫 글자가 영어로 나오면 블립 타이밍 문제.

6. **끝나고** — config 삭제(`rm -r ~/.config/remote-ime-sync`)하고 Karabiner 룰 복원
   (vault `dotfiles/karabiner/karabiner.client.json` 다시 복사).

## tart VM 테스트 리그 (2026-09-01 구축, 재사용 가능)

호스트 맥 안에 macOS VM 을 띄워 클라이언트 역할을 시킨다. Karabiner 를 건드리지
않고 반복 테스트할 수 있어서 맥북보다 편하다.

```sh
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ime-test   # 게스트는 호스트보다 낮은 버전
tart set ime-test --memory 8192 --cpu 4
tart run ime-test --dir=share:<바이너리 둘 폴더> &
tart ip ime-test            # ssh admin@<ip>, 비번 admin (키 넣어두면 편함)
```

- 게스트에 한국어 입력 소스 추가: `defaults export com.apple.HIToolbox` → plist 의
  `AppleEnabledInputSources` 에 `com.apple.inputmethod.Korean(.2SetKorean)` 항목 추가 →
  `defaults import` → **재부팅**(로그아웃만으론 반영 안 될 때가 있음).
- Jump 뷰어는 App Store 말고 직접 다운로드판: `https://jumpdesktop.com/downloads/jdmac`
  (zip. 14일 트라이얼). 뷰어 bundle id = `com.p5sys.jump.mac.viewer.web`.
- 앱은 GUI 세션에서 띄워야 한다: `sudo launchctl asuser $(id -u admin) sudo -u admin <바이너리>`
- 게스트 화면 캡처는 게스트 안에서 `screencapture -x` 후 scp (호스트에서 VM 창을 찍는 것보다 깨끗).
- 호스트 도착 여부 관측: `JumpModifierFix --observe` — keyDown 과 flagsChanged 를
  srcPID 와 함께 찍는다. srcPID 가 JumpConnect 면 원격에서 온 것, 0이면 물리 키.

## 2026-09-01 실측 결과

**sendAs 동작 확인.** Cmd+Space → 게스트 로컬 전환 + 호스트 ⌃⌥⌘Space 전환 둘 다 됨.
게스트의 시스템 Cmd+Space(Spotlight)는 **울리지 않았다** — 세션 탭이 심볼릭 핫키보다
먼저 돈다는 것이 실측으로 확인됐고, 따라서 로컬 이중 토글도 없다. 재정렬
(Cmd+Shift+Space)도 호스트만 전환되는 것 확인.

**전제 뒤집힘 ④ — keyDown 의 flags 만 고치면 안 된다.** 처음엔 이벤트를 in-place 로
고쳐 내보냈는데, 호스트 관측기에 `keyDown code=49 cmd=1 opt=1 ctrl=1` 로 **정확히
도착했는데도** 핫키가 안 울렸다. 원격 데스크탑은 모디파이어 상태를 flagsChanged 로
따로 전달하기 때문에, ⌃·⌥ 의 press/release 이벤트까지 합성해야 한다.

**남은 것 — 호스트 쪽 ~20% 미발화.** 합성 시퀀스는 성공·실패 케이스가 관측기에서
**완전히 동일**하다(⌘release → ⌃down → ⌘down → ⌥down → space down → 역순 해제).
그런데도 호스트 핫키는 대략 4번 중 3번만 반응한다. sendStepMs 를 25→60ms 로 늘려도
비율이 안 바뀌었으니 우리 쪽 타이밍 문제는 아니고, **전달 이후 호스트 단계**의 문제다.

**결론(2026-09-01, 잭 실기기 확인): 앱 문제가 아니다.** Karabiner 룰에서도 연속으로
계속 누르면 똑같이 씹히고, 중간에 타이핑을 끼우면 안 씹힌다. 즉 **연타 시 미발화는
경로와 무관한 호스트 특성**이고, 자동 테스트가 2.5초 간격으로 타이핑 없이 계속
누른 것이 정확히 그 조건이었다. 실사용(타이핑 사이사이 전환)에서는 재현되지 않는다.
