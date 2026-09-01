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

## 통과하면 다음

`sendAs` 구현 — Cmd+Space 를 받아 ⌃⌥⌘Space 로 **바꿔서** 내보낸다. 미검증 리스크:
세션 탭에서 keyDown 의 flags 만 고쳐도 Jump 가 모디파이어 상태를 flagsChanged 로
따로 추적한다면 호스트에 ⌃⌥ 가 안 눌린 것으로 보일 수 있다. 실측으로 확인할 것.
