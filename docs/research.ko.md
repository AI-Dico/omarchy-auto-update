# Omarchy Auto Update 플러그인 — 타 OS 자동 업데이트 조사 (2026-10-20)

표기: [1차] = 공식 문서·소스에서 직접 확인, [2차] = 블로그·포럼·서드파티, [미확인] = 기억 기반이라 재검증 필요.

---

## 0. 결론 요약

- 성숙한 OS 는 모두 **"내려받기·준비는 조용히, 전환은 원자적으로, 확정은 부팅이 증명한 뒤에"** 구조다. 전환(커밋)과 확정(bless)이 분리돼 있다는 점이 핵심이다.
- 실행 중 세션의 라이브러리를 바꿔치기하는 시스템은 없다. A/B 슬롯(ChromeOS·Android·SteamOS), 스냅샷 기반 새 루트(transactional-update·rpm-ostree·macOS SSV), 오프라인 부팅 모드(systemd system-update.target·PackageKit) 중 하나를 쓴다.
- 자동 롤백의 공통 요소 = **시도 횟수 카운터(보통 3) + 사용자 공간 헬스체크 + "성공" 표시 전까지 이전 버전 보존**.
- Arch 는 부분 업그레이드를 지원하지 않는다. 그래서 "보안 패치만 먼저 자동 적용" 같은 패키지 단위 선별은 불가능하다. 선별 단위는 패키지가 아니라 **트랜잭션 전체(= 한 시점의 동기 DB 스냅샷)** 여야 한다.
- 현재 Omarchy(omacom/omarchy `bin/`)에는 이미 10 GiB 여유 공간 검사, pacman 직접 업그레이드 가드, snapper 스냅샷, 커널 갱신 시 재부팅 확인, limine-snapper-restore 가 있다. 플러그인은 이것을 재사용하고 "배경 다운로드·DB 고정·부팅 확정·자동 롤백" 네 가지를 덧붙이는 형태가 맞다.

---

## 1. OS 별 메커니즘

### 1.1 ChromeOS — update_engine A/B [1차]
출처: https://chromium.googlesource.com/aosp/platform/system/update_engine/+/HEAD/README.md
- 커널·루트(DLC 포함)가 두 벌. 비활성 슬롯에만 쓴다. 성공하면 비활성 슬롯의 우선순위를 올린다.
- 검증 3단: (1) 서버 응답의 서명으로 **메타데이터 먼저** 검증, (2) 다운로드 중 SHA256 해시, 끝에서 페이로드 서명 확인 — "If the signature cannot be verified, the update is rejected." (3) 쓰기 후 **비활성 파티션 전체를 다시 읽어** 메타데이터 해시와 대조.
- postinstall 이 dm-verity 해시 트리를 재구성. "If postinstall fails, the entire update is considered failed."
- 새 슬롯으로 부팅한 뒤 `chromeos-setgoodkernel` 이 dm-verity 로 무결성을 확인하고 "정상"으로 표시. 부팅에 실패하면 이전 파티션으로 롤백.
- 주기적 체크포인트로 **중단 지점에서 재개**. 델타가 반복 실패하면 전체 페이로드로 전환.
- 숨은 안전장치: 비활성 파티션을 건드리는 순간 그쪽으로의 롤백은 불가능해진다 → "이전 버전 보존" 슬롯을 덮어쓰기 전에 현재 부팅이 확정돼 있어야 한다.
- GPT 속성 비트(priority·tries·successful) 세부는 chromium.org 디스크 포맷 문서가 404 라 이번엔 직접 확인하지 못함 [미확인: priority 4bit, tries 4bit, successful 1bit].

### 1.2 Android — A/B · Virtual A/B [1차]
출처: https://source.android.com/docs/core/ota/ab , https://source.android.com/docs/core/ota/virtual_ab
- 슬롯 상태 3종: bootable / successful / active.
- 업데이트 시작 시 **현재 슬롯을 successful 로 먼저 표시**하고, 대상 슬롯은 setSlotAsUnbootable 로 부팅 불가 처리 → 쓰는 도중의 슬롯으로 부트로더가 넘어가는 일을 막는다.
- 재부팅 후 `update_verifier` 가 **zygote 시작 전**에 dm-verity 로 care_map 블록만 읽어 검증 — "to avoid Java services making any irreversible changes". 통과하면 markBootSuccessful.
- 부트로더는 "some number of attempts" 후 이전 슬롯으로 폴백(횟수는 문서에 고정값 없음).
- postinstall: 새 파티션의 프로그램을 **구 시스템이 도는 동안** 제한 SELinux 컨텍스트에서 실행, exit 0 아니면 실패.
- 배경 동작: I/O 부하를 의도적으로 낮게, 배터리 잔량에 따라 다운로드·적용 연기, OEM 에는 "idle maintenance mode, such as overnight, and on Wi-Fi" 권장.
- Virtual A/B: 델타를 스냅샷(COW)에 쓰고 **부팅 성공을 확인한 뒤에야** 베이스 파티션에 병합. 병합 중 재부팅해도 재개. 실패 시 자동 롤백. 공간 요구는 재부팅 전까지만 일시적(압축 COW 로 약 45~55% 절감).
- 옮길 점: **"병합(=구버전 폐기)은 부팅 확정 후"** — snapper 로 치면 사전 스냅샷 정리(cleanup)를 새 부팅이 bless 되기 전엔 하지 않는다.

### 1.3 systemd 부팅 평가 (boot counting) [1차]
출처: https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/
- 엔트리 파일명에 `+3` → `+2-1` → `+1-2` → `+0-3` 처럼 남은/한 시도 횟수를 기록.
- `boot-complete.target` 에 도달하면 `systemd-bless-boot.service` 가 카운터를 지워 "good" 표시. 헬스체크 유닛은 이 타깃 **앞에** 두고 타깃이 `Requires=` 로 끌어온다. 하나라도 실패하면 bless 안 됨.
- 카운터 0 = "bad", 부트로더가 다른 엔트리 뒤로 정렬 → 자동으로 이전 버전 부팅. `systemd-bless-boot bad` 로 즉시 bad 표시 가능.
- Omarchy 는 limine 이라 이 메커니즘을 그대로 쓰지는 못한다(limine 의 boot counting 지원 여부 [미확인]). 같은 의미론을 플러그인이 구현해야 한다(아래 권장 4).

### 1.4 openSUSE MicroOS / Tumbleweed — transactional-update + health-checker [1차]
출처: https://kubic.opensuse.org/documentation/man-pages/transactional-update.8.html , https://github.com/openSUSE/health-checker
- snapper 로 루트의 새 스냅샷을 만들고 **그 안에서** zypper 를 실행. 실행 중 시스템은 손대지 않는다. 성공하면 새 스냅샷을 다음 부팅 기본값으로 지정하고 읽기 전용으로 만든다. 실패하면 새 스냅샷을 삭제(종료 코드 1).
- 매 실행은 **현재 실행 중 루트에서 분기**(재부팅 전 이전 변경은 이어받지 않음). `--continue` 로 이어 쌓기 가능.
- /etc: 읽기 전용 시스템은 스냅샷별 overlay. 재부팅 전 실행 중 /etc 변경과 업데이트 변경이 충돌하면 "only the version of the new snapshot will be visible after a reboot" + 첫 부팅 때 경고. 읽기-쓰기 시스템은 스냅샷 생성 후 루트 변경이 다음 재부팅에 사라지므로 **곧바로 재부팅 권고**.
- 재부팅은 `rebootmgrd` 정책(유지보수 창)에 위임.
- health-checker: 부팅 중 플러그인(`/usr/libexec/health-checker`, `/usr/local/libexec/health-checker`)을 `check` 로 실행. systemd-boot/grub2-bls 에서는 스냅샷별 엔트리에 시도 카운터 **기본 3**(`/etc/kernel/tries`), 실패 시 다음 스냅샷으로 재부팅 롤백, 성공 시 systemd-bless-boot. 이전에 정상이던 엔트리가 깨지면 **1회 재부팅 시도 후 비상 셸**. 레거시 grub: 마지막 정상 서브볼륨과 다르면 자동 롤백 → 이미 정상이던 스냅샷이면 1회 재부팅(시각 기록) → 그래도 실패하면 모든 플러그인 `stop` 후 관리자 접근용으로 띄워 둠.
- 숨은 안전장치: **재부팅 루프 방지(재시도 1회 기록 파일)**, "최종 정상 스냅샷" 번호를 `/var/lib/misc/health-check.state` 에 영속화.

### 1.5 Fedora Silverblue — rpm-ostree [1차/미확인 혼합]
출처: https://coreos.github.io/rpm-ostree/
- 이미지 기반·버전·체크섬 있는 트랜잭션 업그레이드, /usr 만 롤백하고 /etc·/var 는 유지 [1차].
- [미확인] 자동 업데이트 정책 `AutomaticUpdatePolicy=none|check|stage` — stage 는 새 배포를 내려받아 준비하고 **종료 시 최종화(finalize)** 한다. /etc 는 3-way merge. auto-updates 문서 URL 이 404 라 이번엔 직접 확인 못함.

### 1.6 systemd 오프라인 업데이트 + PackageKit/GNOME Software [1차]
출처: https://www.freedesktop.org/software/systemd/man/latest/systemd.offline-updates.html , https://blogs.gnome.org/hughsie/2018/08/08/gnome-software-and-automatic-updates/
- 패키지를 `/var/lib/system-update` 같은 곳에 **미리 내려받고**, 사용자 승인 후 `/system-update` 심링크 생성 → 재부팅 → generator 가 그 부팅만 `system-update.target` 으로 전환 → 최소 시스템에서 설치 → 재부팅.
- 숨은 안전장치:
  - 심링크를 **스크립트 초반에 제거** — 실패해도 재부팅 루프가 안 생긴다. 타깃 도달 시 링크가 남아 있으면 systemd 가 지우고 재부팅.
  - `FailureAction=reboot` 로 비정상 종료 시에도 재부팅.
  - "It is unsafe to run multiple updates in parallel" — 심링크 대상과 일치하는 업데이터 하나만 동작.
  - 가능하면 설치 전 파일시스템 스냅샷, 실패 시 스냅샷으로 되돌림.
  - 링크는 루트 FS 에 둔다(/var 마운트 전 확인해야 하므로).
- GNOME Software: 자동 **설치**는 Flatpak 만. OS 패키지·펌웨어·ostree 는 자동 **다운로드**만 하고 배포는 수동. 계량 연결·배터리 로직은 자동 다운로드 설정과 별개로 유지 [1차 블로그]. 계량 연결에서는 자동 다운로드 안 함 [2차 포럼: https://discussion.fedoraproject.org/t/using-gnome-software-for-updates-on-a-metered-connection-on-fedora-silverblue/94455].
- [2차] 준비된 오프라인 업데이트가 오래되면 PackageKit 이 폐기하고 다시 준비하는 버그 보고(https://bugzilla.redhat.com/show_bug.cgi?id=2457884) → **준비물에 유효기간이 있다**는 신호.
- [미확인] gs-update-monitor 알림 빈도: 보안 업데이트는 매일, 일반은 주 1회.

### 1.7 Ubuntu — unattended-upgrades · phased updates [1차]
출처: https://github.com/mvo5/unattended-upgrades/blob/master/data/50unattended-upgrades.Ubuntu , https://ubuntu.com/project/docs/how-ubuntu-is-made/concepts/phased-updates/
- 자동 설치 범위 = **Allowed-Origins 기본값이 `-security` 포켓**. 주석: 보안 업데이트가 비보안 소스에서 새 의존성을 끌어올 수 있다.
- `Package-Blacklist`, `MinimalSteps`(작은 단위로 나눠 SIGTERM 으로 중단 가능 → 종료 지연 최소화), `InstallOnShutdown`(logind `InhibitDelayMaxSec` 30s 로 올림, 30분 권장 언급), `OnlyOnACPower`, `Skip-Updates-On-Metered-Connections`, `Automatic-Reboot`(기본 false) · `-WithUsers` · `-Time "02:00"`.
- Phased updates: 10% 시작, **6시간마다 +10%p**, 약 54시간에 100%. 회귀(크래시 DB 등) 감지 시 **0%로 내려 배포 중단**. 기기 선택 = (패키지명+버전+machine-id) 해시 → 0~100, 현재 비율보다 작으면 포함. 패키지·버전마다 시드가 달라 **같은 사용자만 매번 첫 타자가 되지 않음**.

### 1.8 Windows Update [1차]
출처: https://learn.microsoft.com/en-us/windows/deployment/update/waas-restart , https://learn.microsoft.com/en-us/windows/deployment/update/wufb-compliancedeadlines , https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds , https://support.microsoft.com/en-us/windows/recovery-options-in-windows-31ce2444-7de3-818c-d626-e3b5a3024da5
- 활성 시간 기본 08~17시, 최대 범위 18시간(구버전 12). 자동 재시작은 활성 시간 밖에서만.
- 레거시: 재시작 기한 기본 7일, 2~14일 설정. 7일 지나면 "engaged restart"(사용자가 시각을 정하는 단계)로 전환, 스누즈 일수 제한.
- 현행 기한 정책: **effective deadline = max(발견 시각+기한, 재시작 대기 시각+유예기간)**. 유예기간은 "휴가에서 돌아온 사용자"가 즉시 강제 재시작을 당하지 않게 하는 장치. 권장값 품질 0~1일 / 기능 2일 / 유예 2일.
- 알림 계단: 재시작 대기 진입 24시간 뒤 토스트(옵션 켜면 즉시 + **24시간 자동 재시작 차단**) → 예약 15분 전 알림 → 기한 15분 전 화면 중앙 대화상자 → 기한 경과 후 재시작 실패 시 전원 연결 상태면 5분마다 재시도.
- "로그인 사용자 있으면 재시작 안 함" 정책은 **사용자가 로그오프를 안 해서 영원히 재부팅이 안 되는 문제**가 있다고 MS 스스로 명시 → 기한을 반드시 둔다.
- 유지보수 창: 창 끝 30분 전 이후로는 재시작을 **시작하지 않음**(예: 06시 종료면 05:30 이후 시작 금지). 1회성 창은 90일 넘게 지나면 무시.
- 일시정지: 기본 최대 5주(35일), 한도 도달 시 업데이트 설치 전엔 재일시정지 불가 [2차: elevenforum].
- 이전 버전으로 되돌리기: 기능 업데이트 후 **10일**. 이후 추가된 앱·드라이버·설정은 제거.
- Known Issue Rollback: 수정마다 런타임 기능 플래그, 클라우드 정책으로 문제 수정만 이전 코드 경로로. **비보안 수정에만** 적용(구 경로가 더 취약하므로) [2차 집계: Neowin·Computerworld 등 / MS 원문 페이지 404].
- Safeguard hold: 드라이버·앱 호환성 데이터로 알려진 문제 기기에는 **업데이트 제공 자체를 보류**. 사용자에게는 "준비 중" 메시지만.

### 1.9 macOS [1차]
출처: https://support.apple.com/guide/security/signed-system-volume-security-secd698747c9/web , https://support.apple.com/guide/security/background-security-improvements-sec87fc038c2/web , https://support.apple.com/guide/deployment/about-software-updates-depc4c80847a/web
- SSV: 시스템 볼륨 전체에 해시 트리 seal. 업데이트 시 seal 을 기기에서 재계산, 부트로더가 커널 넘기기 전 검증. 실패하면 부팅 중단·재설치 유도. APFS 스냅샷이라 실패한 업데이트를 재설치 없이 되돌릴 수 있다.
- 자동 업데이트 전원 조건: 다운로드·준비는 **전원 연결 필요**, 자동 설치는 배터리 50% 이상. BSI 는 10%(Apple silicon)/20%(Intel).
- Background Security Improvements(26.1~, RSR 후속): 패치 대상(Safari·WebKit·시스템 라이브러리)을 cryptex(봉인 디스크 이미지, preboot 볼륨)로 분리 → **시스템 볼륨 재봉인 불필요**. 재시작 시 즉시 활성, Safari 만이면 앱 재실행으로 충분, 나머지 OS 는 다음 재시작까지 구버전 사용. 패치마다 **antipatch 동봉** → 사용자 제거 가능, Apple 이 원격 제거 가능, 크래시 증가와 연관되면 크래시 후 제거를 제안. 누적형(a,b,c…), 최신 OS 에만.
- 기업 관리 배포 지연은 90일 기준 표기 [1차].
- [미확인] 사용자 UI: "오늘 밤 시도"(전원 연결 시 야간 설치)·"내일 다시 알림", 단계적 배포.

### 1.10 SteamOS [2차]
출처: https://collabora.com/news-and-blog/news-and-events/steamos-3-6-how-the-steam-deck-atomic-updates-are-improving.html
- A/B 파티션, RAUC + casync(→desync) 로 원자적 이미지 적용. 새 버전 부팅 실패 시 이전 파티션으로 자동 복귀. RAUC 일반 동작은 "boot into the newly written slot **once**" 플래그로 미검증 이미지의 안전한 폴백 보장.

### 1.11 NixOS [1차]
출처: https://nixos.org/manual/nixos/stable/#sec-upgrading-automatic
- `system.autoUpgrade.enable` → `nixos-upgrade.service` 타이머. `allowReboot=false` 면 `nixos-rebuild switch --upgrade`, true 면 **커널·initrd·모듈이 바뀐 경우에만** 재부팅.
- 세대(generation)마다 부트 메뉴 항목. `switch`(지금 적용+부팅 기본), `test`(지금만, 재부팅하면 원복), `boot`(다음 부팅부터) 세 가지 적용 모드 구분.
- [미확인] `rebootWindow`, `randomizedDelaySec`, `persistent` 옵션.

### 1.12 Arch 계열 [1차/2차]
출처: https://wiki.archlinux.org/title/System_maintenance (raw 로 확인), https://wiki.archlinux.org/title/Snapper , https://gitlab.archlinux.org/pacman/pacman-contrib/-/raw/master/src/checkupdates.sh.in , https://github.com/Antiz96/arch-update
- 업그레이드 전 Arch 뉴스 확인 기대. pacman 훅(informant·newscheck·arch-manwarn)으로 **안 읽은 뉴스가 있으면 업그레이드 차단** 가능.
- "Partial upgrades are unsupported": `pacman -Sy pkg`, `-Sy` 후 `-S pkg` 금지. **`pacman -Syuw` 도 `-Sy` 와 같은 위험**(DB 만 갱신하고 설치는 안 함). IgnorePkg/IgnoreGroup 도 같은 이유로 주의. `-Syu` 가 `-Su` 단계에서 실패하면 다른 패키지 작업 전에 반드시 완료해야 함.
- `checkupdates` 는 **임시 DB(`${TMPDIR}/checkup-db-${UID}`)를 fakeroot 로 동기화** → 시스템 DB 를 건드리지 않고 업데이트 목록 계산. `-d` 는 그 임시 DB 로 `pacman -Sw` 를 **root 로** 실행해 캐시에 다운로드.
- 업그레이드는 실행 중 프로세스에 적용되지 않음 → 재시작 필요. `checkservices`(archlinux-contrib)가 pacdiff 후 구 라이브러리 쓰는 프로세스 재시작 제안. 커널은 재부팅이 가장 안전.
- Snapper 위키: 스냅샷은 기본 읽기 전용이라 직접 부팅하면 /var 쓰기가 필요한 서비스가 실패. **ESP 같은 비-btrfs /boot 는 스냅샷에 포함되지 않음** → 커널 업데이트 시 /boot 를 btrfs 루트로 복사하는 훅 필요. limine-snapper-sync 가 snap-pac 스냅샷을 Limine 항목으로 추가.
- arch-update(Antiz96): 부팅 시 + 6시간마다 **확인만** 자동, 적용은 사용자 클릭. 뉴스·고아 패키지·캐시·pacnew·커널 재부팅·서비스 재시작을 적용 흐름에 포함.
- Manjaro: 자체 저장소가 Arch 패키지를 unstable→testing→stable 로 지연 배포(pamac 업데이트 알림) [미확인, 1차 미확인]. EndeavourOS·CachyOS: snapper/grub-btrfs·limine 기반 스냅샷 부팅을 제공하나 **완전 무인 자동 적용 도구는 기본 제공하지 않는 것으로 보임** [2차, 확인 부족].
- 결론: Arch 생태계 도구들은 "자동 확인 + 수동 적용"이 표준이다. 무인 자동 적용은 Arch 위키가 권장하지 않는 영역(뉴스 개입 필요성 때문)이므로 플러그인의 자동 적용 범위는 보수적이어야 한다.

### 1.13 현 Omarchy 상태 (로컬 소스 확인)
omacom/omarchy `bin/`
- `omarchy-update-requires-free-space`: 루트 여유 10 GiB 미만이면 중단.
- `omarchy-update-pacman-guard`: omarchy update 를 우회한 직접 `pacman -Syu` 차단.
- `omarchy-snapshot create|restore`: snapper 모든 config 에 number 스냅샷 + cleanup, restore=limine-snapper-restore. config 0개면 "복구 가능해 보이는 착시"를 막으려 실패 처리.
- `omarchy-update-restart`: 실행 커널과 설치 커널 비교로 재부팅 필요 판단, `OMARCHY_UPDATE_UNATTENDED=1` 이면 묻지 않고 안내만.
- `omarchy-update-available`: `checkupdates` 로 omarchy 패키지 갱신 여부 확인.
- 그 외 omarchy-update-keyring, -stay-awake, -lock, -firmware, -analyze-logs 존재.

---

## 2. 질문별 정리

### Q1. 단계와 단계별 확인 항목
| 단계 | 확인 | 근거 |
|---|---|---|
| 확인(check) | 미러 신선도, 뉴스, 제공 보류 목록(safeguard 대응), 단계 배포 해시 | Arch 위키 뉴스, Windows safeguard, Ubuntu phased |
| 다운로드 | 비계량 네트워크, AC 전원(또는 배터리 하한), 낮은 I/O 우선순위, 중단 재개 | GNOME, unattended-upgrades, Android, ChromeOS |
| 검증 | 서명(메타데이터 먼저 → 본문), 해시, 디스크 여유(설치+스냅샷), 의존성 해결 dry-run | ChromeOS, Omarchy 10GiB |
| 준비(stage) | 새 루트/오프라인 대상 마련, postinstall 성공 여부 | transactional-update, Android postinstall |
| 적용(commit) | 유휴·활성 시간 밖·전원·사용자 동의/기한, 단일 실행 잠금 | Windows, systemd offline |
| 확정(bless) | 부팅 카운터, 헬스체크, 그 뒤에야 구버전 정리 | systemd boot assessment, Virtual A/B |

### Q2. 자동 vs 동의 경계
- Ubuntu: 기본 자동 범위는 보안 포켓, 재부팅은 기본 비활성.
- GNOME: 자동 설치는 앱(Flatpak)만, OS 는 다운로드까지만.
- macOS: 보안 개선(BSI)은 가볍게·자동, OS 업데이트는 전원·배터리 조건과 사용자 일정.
- Windows: 설치는 자동, **재시작만** 사용자와 협상. 연기는 무한이 아니라 기한+유예.
- 공통 원칙: 경계선은 "보안이냐 기능이냐"보다 **"재시작이 필요한가 / 되돌릴 수 있는가"**. 실행 중 세션에 영향을 주는 것은 동의 대상.

### Q3. 실패 감지·자동 롤백
- 시도 횟수: systemd/openSUSE 기본 3. Android 는 구현 정의.
- 검증 시점: Android 는 zygote 전(되돌릴 수 없는 변경 전에), systemd 는 boot-complete.target 전.
- 루프 방지: openSUSE 는 정상이던 엔트리가 깨지면 재부팅 1회 후 비상 셸, systemd offline 은 심링크 선삭제.
- 롤백 이후: BSI 는 크래시 증가 시 제거 제안, Ubuntu 는 서버 측 배포 중단.

### Q4. 실행 세션 보호
- 새 루트에 설치 후 재부팅(transactional-update, rpm-ostree, A/B), 또는 최소 부팅 모드에서 설치(system-update.target).
- 예외적으로 즉시 적용하는 것은 **격리된 단위**만: macOS BSI 의 Safari 재실행, GNOME 의 Flatpak, transactional-update `apply`(서비스 재시작 안 함).
- 실행 중에 적용했다면 재시작 필요 프로세스를 찾아 안내(checkservices, arch-update).

### Q5. Arch 부분 업그레이드 제약의 영향
- "보안 패키지만 먼저 설치"는 Arch 에서 금지된 부분 업그레이드다. soname 변경 시 다른 패키지가 깨진다.
- `-Syuw` 로 미리 받는 것도 시스템 DB 를 갱신하므로 위험 → **시스템 DB 를 건드리지 않는 별도 DB 경로**(checkupdates 방식)로 받아야 한다.
- 따라서 "일부 먼저"의 단위는 패키지가 아니라 **"전체 트랜잭션을 어느 시점에 적용하느냐"**. 영향 크기는 트랜잭션 전체를 보고 분류(커널·glibc·mesa·hyprland·systemd 포함 여부 등)해, 작은 트랜잭션은 자동 적용, 큰 트랜잭션은 "재시작하면 적용"으로.
- 다운로드 시점과 적용 시점 사이에 미러가 움직이면 다른 트랜잭션이 된다 → 다운로드에 쓴 **동기 DB 스냅샷을 고정**하고 적용 때 그 DB 로 `-Su`(새 `-y` 없이) 해야 검증한 것과 적용하는 것이 같다. 대안은 Arch Linux Archive 날짜 고정 미러.
- AUR 은 soname 변경 시 재빌드 필요 → 자동 적용 범위에서 제외하고 별도 동의.

---

## 3. 권장 Top 10 (근거 OS)

1. **단계 분리: 확인 → 다운로드 → 검증 → 준비 → 적용 → 확정.** 사용자 권한 샌드박스는 다운로드·검증까지만, 적용은 root 단일 실행. (ChromeOS, systemd offline)
2. **동기 DB 고정.** checkupdates 처럼 임시 dbpath 를 fakeroot 로 동기화하고 그 DB 로 받는다. 적용 시 같은 DB 로 `-Su`, 시스템 DB 에 `-Sy` 단독 금지. 적용 직전 미러 lastsync 가 다운로드 시점보다 과거면 중단. (Arch 위키 partial upgrade, checkupdates 소스)
3. **다운로드 조건 게이트**: NetworkManager 계량 연결이면 다운로드 금지, AC 전원(또는 배터리 50% 이상), ionice/nice idle, 중단 재개. (GNOME, unattended-upgrades, macOS 전원 조건, Android)
4. **부팅 확정(bless) 의미론 구현**: 새 스냅샷/부팅에 시도 카운터 3, `boot-complete.target` 전에 헬스체크(Hyprland 세션 기동·네트워크·failed unit 0), 통과 시에만 "정상" 기록. 실패 3회면 직전 정상 스냅샷으로. 정상이던 것이 깨지면 재부팅 1회 후 멈춤(루프 방지). (systemd boot assessment, openSUSE health-checker, Android update_verifier)
5. **구버전 정리는 확정 뒤에만**: 업데이트 전 스냅샷과 이전 커널·initramfs 를 bless 전엔 snapper cleanup 대상에서 제외. (Virtual A/B 병합 시점, ChromeOS 비활성 파티션 보존)
6. **/boot(ESP) 정합성**: Omarchy 의 limine+snapper 는 ESP 가 스냅샷에 안 들어가므로 롤백 대상 스냅샷과 커널·initramfs 짝이 맞는지 검증한다. 스냅샷 부팅은 읽기 전용이라 /var 쓰기 문제를 확인. (Arch Snapper 위키)
7. **영향 분류는 트랜잭션 단위**: 커널·glibc·systemd·mesa·hyprland·드라이버 포함이면 "재시작하면 적용"(오프라인/다음 부팅 적용), 그 외 작고 재시작 불필요한 것만 동의 범위 내 자동 적용. 자동 적용 뒤엔 checkservices 식으로 재시작 필요 프로세스 안내. (NixOS 커널 변경시만 재부팅, Ubuntu 보안 포켓, GNOME Flatpak만 자동)
8. **오프라인 적용 안전장치**: "재시작하면 적용"은 system-update.target 패턴으로. 트리거 링크는 스크립트 시작에 삭제, `FailureAction=reboot`, 사전 스냅샷, 동시 실행 금지. 준비물에 유효기간(예: 동기 DB 가 N일 지나면 재준비). (systemd offline updates, PackageKit 버그)
9. **연기는 기한+유예, 알림은 계단식**: 활성 시간 밖에서 재시작 제안, 대기 24시간 뒤 첫 알림, 기한 = max(발견+기한, 대기+유예) 로 휴가 복귀 직후 강제 금지. 로그인 상태라 영원히 미루는 구조를 피하되, 데스크톱 OS 특성상 강제 재시작은 하지 않고 알림 강도만 올린다. 창 끝 30분 전엔 재시작을 시작하지 않는다. (Windows 기한·engaged restart·유지보수 창)
10. **배포 측 안전망**: Arch 뉴스에 수동 개입 항목이 있으면 자동 적용 중단(informant 방식), 해시(machine-id+버전) 기반 단계 배포·서버 측 중단 스위치, 문제 패키지 보류 목록 원격 배포. (Ubuntu phased, Windows safeguard hold, Arch 뉴스 훅)

추가 고려: 보안 대 기능 분리로 "보안만 먼저"를 원하면 Arch 에서는 패키지 선별이 아니라 **적용 주기 차등**(보안 공지가 걸린 트랜잭션은 기한 짧게)으로 구현한다. macOS BSI 같은 분리 배포 단위는 Arch 에 없다.

---

## 4. 확인하지 못한 것 (재검증 필요)
- ChromeOS GPT 속성 비트 정확한 정의(문서 404).
- rpm-ostree AutomaticUpdatePolicy 세부(문서 404).
- Windows KIR MS 원문(404, 2차 출처로만 확인), 일시정지 35일(2차).
- macOS 사용자 UI 문구·단계적 배포, RSR 과 BSI 의 관계 세부.
- limine 의 boot counting 지원 여부, limine-snapper-sync 의 ESP 커널 처리 방식(README 미열람).
- Manjaro·CachyOS·EndeavourOS 도구 1차 문서.
- `pacman -Sw` 가 다운로드 단계에서 서명 검증까지 하는지, 사용자 권한 cachedir 로 동작하는지 실측 필요.
