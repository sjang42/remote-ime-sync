---
title: remote-ime-sync 세션 핸드오프 — Jump Desktop 한영 동기화 (Karabiner 룰 + standalone 앱)
type: handoff
status: 앱 v0.1 커밋·push 완료 · 클라이언트(맥북) 실사용 검증 대기 · 배포 방향 미정
last_updated: 2026-08-22
claude_cwd: /Users/jex/work/remote-ime-sync (일부 작업은 vault 루트)
branch: main
sessions:
  - 45530cb3-d314-4c1e-9485-23b4c61b3b27  # 주 세션 (2026-08-21 ~ 08-22 KST, 호스트 맥에서 실행)
---

# remote-ime-sync — Jump Desktop 한영 동기화

## 0. 미션

Jump Desktop(Fluid, Mac→Mac)에서 로컬·호스트 입력소스가 어긋나면 타이핑이 깨지는
문제를 푼다. 산출물은 두 층위:
1. 잭 개인용 — 클라이언트(맥북) Karabiner 룰 (지금 실사용 중인 안정 버전)
2. 제품용 — standalone 앱 `RemoteIMESync` (이 repo, 오픈소스 공개 또는 판매 후보,
   "프로/무료 나누지 말고 일단 앱으로"가 잭의 마지막 결정)

세션은 호스트 맥에서 돌았다. 클라이언트(맥북) 쪽 실기기 검증은 잭이 직접 한다.

## 1. 한 것

1. 원리 확립 + 실측 (2026-08-21)
   - 아키텍처 = "키 하나, 이벤트 하나, 효과 둘": 클라이언트가 트리거 키를 관찰해
     자기 소스만 TIS 로 바꾸고 이벤트는 통과 → Jump 가 호스트로 전달 → 호스트의
     시스템 한영 단축키(심볼릭 핫키 60)가 호스트를 토글. 호스트 설치물 0.
   - 전제 뒤집힘 ①: 호스트 Karabiner 로 원격 키를 받으려던 최초 계획(F17/F18
     패스스루)은 폐기 — 원격 데스크탑이 주입하는 키는 CGEvent 라 Karabiner(HID
     grab)를 완전히 우회한다 (osascript 주입으로 실측). 반면 macOS 심볼릭 핫키는
     주입 키에 정상 반응한다 (역시 실측).
   - 전제 뒤집힘 ②: "클라이언트 ABC 고정 + 호스트만 전환" 단순안은 잭이 실사용으로
     기각 — Mac→Mac 은 그 조합도 깨진다. 동기화가 필수.
   - ssh+macism 안은 잭이 명시적으로 기각 ("SSH 말고") — 키 팬아웃 방식 채택.
2. 개인용 Karabiner 룰 (vault 커밋 8b5e034f, 이후 fix 커밋)
   - vault `dotfiles/karabiner/karabiner.client.json` = 호스트 전체 룰셋 + sync 룰.
     공개 gist 미러: https://gist.github.com/sjang42/6b6efbe33dc9f5175929b291763ec446
   - Cmd+Space(Jump frontmost) → 클라이언트 소스 전환 + Cmd+Space 통과.
     Cmd+Shift+Space = 호스트만 토글(재정렬). 잭이 맥북에 설치, "너무 잘된다" 확인.
3. standalone 앱 v0.1 (이 repo, 초기 커밋 + 33ec23b)
   - Swift/SPM, 의존성 0 (AppKit/Carbon). 소스 한 파일 `Sources/RemoteIMESync/main.swift`.
   - 세션 이벤트 탭 head-insert(원격 앱 탭보다 먼저), 시스템 단축키 자동 감지
     (symbolichotkeys 60), config 오버라이드, 메뉴바 상주(⇄한), 재정렬 키.
   - 호스트에서 스모크 테스트 통과 (F18 트리거 + anyApp 테스트 모드, osascript 주입).
4. macOS CJK TIS 버그 확진 + 우회 (2026-08-22, 잭 버그 리포트에서)
   - 증상: 영→한 전환만 메뉴바는 바뀌는데 포커스된 앱(Jump)에 미적용, 다른 앱
     찍고 돌아오면 적용. 한→영은 정상 (비대칭).
   - 원인: TISSelectInputSource 로 CJK "입력기(input mode)" 선택 시 포커스 이동
     전까지 반쪽 적용되는 macOS 버그. 키보드 레이아웃(ABC) 방향은 즉시 적용.
     Karabiner select_input_source 도 동일하게 걸림.
   - 우회 = macism 방식 포커스 블립: 150ms 임시 키 윈도우로 포커스 뺏었다 반환
     (macOS 26 기준 150ms 가 안정 최소값 — macism 소스 주석).
   - 적용: Karabiner 룰은 한글 방향만 `/opt/homebrew/bin/macism ...` 호출로 교체
     (클라이언트에 brew install laishulu/homebrew/macism 필요, gist 갱신됨).
     앱은 자체 focusBlip() 구현 (커밋 33ec23b). 앱 쪽 블립은 트리거 key-up 이
     원격에 먼저 도달하도록 100ms 지연 후 시작.

## 2. 지금 상태

- 이 repo: main, 클린, origin(sjang42/remote-ime-sync, private) 과 동기화됨.
- vault: karabiner.client.json 최신( macism 버전) 커밋·push 됨, gist 도 동일 내용.
- 잭 맥북: 세션 종료 시점 기준 macism 설치 + 새 karabiner.json 재설치를 안내한
  상태 — 실제로 했는지, 영→한 문제가 해결됐는지 미확인. 다음 세션 첫 질문.
- 앱은 맥북에서 아직 한 번도 실행 안 됨.

## 3. 남은 것 (왜 안 했나)

- 클라이언트 실사용 검증 (Karabiner fix + 앱 둘 다) — 맥북 필요, 잭 몫.
- 앱 번들(.app)·서명·노터라이즈 — 실사용 검증 전이라 보류.
- 로그인 자동 실행 (SMAppService) — 번들화 후에 해야 의미 있어 보류.
- sendAs 옵션 (클라·호스트 단축키 다를 때 이벤트를 호스트용 콤보로 변환) — README
  에 planned. 잭 본인 케이스엔 불필요해 후순위.
- 설정 UI/메뉴바 위젯 (v0.2) — 잭이 "궁극적으로 위젯" 방향만 정함.
- 배포 방향 (공개 오픈소스 vs 판매 vs 하이브리드) — 논의만 함. repo 는 그때까지
  private. MAS 는 샌드박스에서 이벤트 탭+TIS 허용 여부 스파이크 후 결정하기로.

## 4. 다음 갈래

1. 잭의 클라이언트 검증 결과 회수 → 문제 있으면 블립 타이밍(100/150ms) 튜닝.
2. 번들화 + 로그인 항목 → "잭 개인용 완성" 라인. (추천 다음 단계)
3. Karabiner 룰 은퇴하고 앱으로 일원화 (앱 검증 통과 시).
4. 배포 결정 + README/네이밍 다듬어 공개.

## 5. 재사용 표면

- 빌드·실행: `swift build -c release && .build/release/RemoteIMESync`
  (Input Monitoring 권한 필요. 메뉴바 ⇄한. 종료는 메뉴바 Quit)
- 테스트 config: `~/.config/remote-ime-sync/config.json` 에
  `{"triggerKeyCode":79,"triggerModifiers":[],"anyApp":true}` → osascript
  `key code 79` 주입으로 GUI 없이 토글 검증 가능. 끝나면 config 삭제(자동 감지 복귀).
- 현재 소스 확인: `macism` (호스트 설치됨) 또는 swift 스니펫 /tmp/cursource.swift.
- 입력소스 ID: ABC=`com.apple.keylayout.ABC`, 한글=`com.apple.inputmethod.Korean.2SetKorean`.
- gist 갱신: `gh api gists/6b6efbe33dc9f5175929b291763ec446 -X PATCH --input <payload.json>`
  (files.karabiner.client.json.content 에 전체 내용).
- vault Karabiner 편집은 반드시 `mac:karabiner` 스킬 워크플로우 (백업→python 편집→
  lint→select-profile). launchctl kickstart 절대 금지.
- 함정: 호스트 Karabiner 룰로는 원격 주입 키 못 받음(CGEvent 우회) / Karabiner sync
  룰과 앱을 동시에 켜면 로컬 이중 토글로 원위치 / TISSelectInputSource 는 CJK
  방향만 포커스 블립 필요 / 맥북 내장 키보드는 vendor_id 0 (is_built_in_keyboard 로 제외).
- 관련 기록: Claude memory `reference_jump_desktop_korean_sync.md`, vault
  `dotfiles/karabiner/`, 스킬 `mac:karabiner`.

## 6. 검증

- `swift build` 통과 + 위 테스트 config 로 F18 주입 → 로그(`NSLog`)에 `local -> ...`
  두 방향 확인이 최소 스모크. 실행 중 앱을 kill 로 죽이면 임시 윈도우가 남을 수 있으니
  메뉴바 Quit 권장 (스모크에선 무해).
- 진짜 검증은 맥북에서 Jump 끼고: 영→한 전환 직후 바로 타이핑되는지 (블립 후
  ~0.3초 내 첫 타 씹힘은 알려진 트레이드오프).

## 다음 세션 시작 프롬프트

```
~/work/remote-ime-sync 의 developing/handoff-remote-ime-sync.md 를 읽고 이어서.
미션: Jump Desktop 한영 동기화 — Karabiner 개인용(안정) + RemoteIMESync 앱(제품용).
먼저 나(잭)에게 맥북 검증 결과부터 물어봐: (1) macism+새 karabiner.json 설치 후
영→한 문제 해결됐는지 (2) 앱 테스트 해봤는지. 그 답에 따라 문서 4절의 갈래를 골라 진행.
```
