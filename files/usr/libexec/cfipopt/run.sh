#!/bin/sh
# luci-app-cfipopt — CF IP 优选测速 backend
# 参考逻辑: cmliu/edgetunnel (生成随机IP / 请求优选API) + XIU2/CloudflareSpeedTest (测速)
# 代理绕过: OpenClash 的 mangle 链自带 skgid 65534 (nobody) 豁免, 测速以 nobody 身份直连
# 用法: run.sh {start|stop|run|proxy|status}

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUN=/usr/libexec/cfipopt/run.sh
TMP=/tmp/cfipopt
CFG=cfipopt

uciget() { uci -q get "$CFG.config.$1" 2>/dev/null; }
ucigetd() { local v; v=$(uciget "$1"); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

log() { echo "$(date '+%H:%M:%S') $*" >> "$TMP/log"; }

# ---------------- proxy detect ----------------
detect_proxy() {
	local active=0 name="" mode="" bypass="none"
	local detail="未检测到代理, 直连测速"
	local oc_en oc_mode oc_pid oc_rule daed_pid daed_en
	oc_en=$(uci -q get openclash.config.enable 2>/dev/null)
	oc_mode=$(uci -q get openclash.config.en_mode 2>/dev/null)
	oc_pid=$(pidof clash 2>/dev/null)
	[ -z "$oc_pid" ] && oc_pid=$(pidof mihomo 2>/dev/null)
	oc_rule=$(ip rule show 2>/dev/null | grep -c "0x162")
	daed_pid=$(pidof daed 2>/dev/null)
	daed_en=$(uci -q get daed.config.enable 2>/dev/null)

	if [ -n "$oc_pid" ] || [ "$oc_en" = "1" ] && [ "$oc_rule" -gt 0 ] || [ "$oc_rule" -gt 0 ]; then
		active=1; name="OpenClash"; mode="${oc_mode:-TUN}"
		bypass="nobody-gid"
		detail="OpenClash 运行中 (${mode}), 测速将以 gid 65534 (nobody) 绕过代理直连"
	elif [ -n "$daed_pid" ] || [ "$daed_en" = "1" ]; then
		active=1; name="DAE"; mode="eBPF"
		bypass="none"
		detail="DAE 运行中 (eBPF 拦截, 无法自动绕过), 请临时关闭 DAE 或在其配置中为 speed.cloudflare.com 添加 direct 规则"
	fi
	printf '{"active":%s,"name":"%s","mode":"%s","bypass":"%s","detail":"%s"}\n' \
		"$active" "$name" "$mode" "$bypass" "$detail" > "$TMP/proxy.json"
}

# ---------------- ip math ----------------
rand32() {
	echo $(( (RANDOM << 17) | ((RANDOM & 0x3FFF) << 2) | (RANDOM & 3) ))
}

ip2int() {
	local a b c d
	IFS=. read -r a b c d <<EOF
$1
EOF
	echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int2ip() {
	local n=$1
	echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

random_ip_in_cidr() {
	local cidr=$1 base prefix hostbits base_int mask r
	base=${cidr%/*}; prefix=${cidr#*/}
	[ "$prefix" -ge 1 ] 2>/dev/null || prefix=24
	[ "$prefix" -le 32 ] 2>/dev/null || prefix=24
	hostbits=$((32 - prefix))
	base_int=$(ip2int "$base") || return 1
	if [ "$hostbits" -lt 31 ]; then
		mask=$((0xFFFFFFFF << hostbits))
		r=$(rand32)
		r=$(( (base_int & mask) | (r & ((1 << hostbits) - 1)) ))
	else
		r=$(rand32)
	fi
	int2ip "$r"
}

pick_port() {
	local list n
	[ -n "$fixed_port" ] && { echo "$fixed_port"; return; }
	list=$ports_str
	set -- $list
	[ $# -eq 0 ] && { echo 443; return; }
	n=$(( (RANDOM % $#) + 1 ))
	eval echo "\${$n}"
}

# ---------------- candidates ----------------
fetch_apis() {
	local urls url uremark body api_count
	api_count=$(ucigetd api_count 30)
	urls=$(uciget api_urls)
	[ -z "$urls" ] && return 0
	log "获取优选API列表..."
	while IFS= read -r url; do
		[ -z "$url" ] && continue
		uremark=""
		case "$url" in
			*\#*) uremark="${url#*\#}"; url="${url%%\#*}";;
		esac
		body=$(curl -s -4 --max-time 10 "$url" 2>/dev/null)
		[ -z "$body" ] && { log "API 无响应: $url"; continue; }
		if [ -n "$uremark" ]; then
			echo "$body" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' \
				| sed "s/$/#$uremark/" | head -n "$api_count" >> "$TMP/candidates.tmp"
		else
			echo "$body" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}(#[^ ]*)?' \
				| head -n "$api_count" >> "$TMP/candidates.tmp"
		fi
		log "API ${url}: 已获取 $(grep -c . "$TMP/candidates.tmp") 条(累计)"
	done <<EOF
$urls
EOF
}

gen_random() {
	local n=$1 cidr_list cidr i ip port
	if [ "$(ucigetd cidr_source official)" = "list" ]; then
		cidr_list=$(uciget cidr_custom)
	else
		cidr_list=$(curl -s -4 --max-time 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null)
		[ -z "$cidr_list" ] && cidr_list=$(uciget cidr_custom)
	fi
	[ -z "$cidr_list" ] && cidr_list="104.16.0.0/13"
	log "CIDR 列表: $(echo "$cidr_list" | wc -l) 条"
	i=0
	while [ "$i" -lt "$n" ]; do
		i=$((i + 1))
		cidr=$(echo "$cidr_list" | awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
		[ -z "$cidr" ] && continue
		ip=$(random_ip_in_cidr "$cidr") || continue
		port=$(pick_port)
		echo "${ip}:${port}" >> "$TMP/candidates.tmp"
	done
}

add_custom() {
	local lines
	lines=$(uciget custom_ips)
	[ -z "$lines" ] && return 0
	echo "$lines" >> "$TMP/candidates.tmp"
}

normalize() {
	local seq=0 line ip rest port rem n
	: > "$TMP/candidates.txt"
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		# 跳过 IPv6 / 非法行 (合法行只含 1 个冒号: ip:port)
		[ "$(echo "$line" | tr -cd ':' | wc -c)" -gt 1 ] && continue
		line=$(echo "$line" | tr -d ' \t')
		ip=${line%%:*}
		rest=${line#*:}
		port=${rest%%#*}
		rem=${line#*#}
		[ "$rem" = "$line" ] && rem=""
		case "$ip" in ''|*[!0-9.]*|*..*) continue;; esac
		case "$port" in ''|*[!0-9]*) port="$fixed_port";; esac
		[ -z "$port" ] && port=443
		seq=$((seq + 1))
		[ -z "$rem" ] && rem="${remark_prefix}${seq}"
		echo "${ip}:${port}#${rem}" >> "$TMP/candidates.txt"
	done < "$TMP/candidates.tmp"
	# 去重 (同 ip:port)
	sort -u -t: -k1,1 -k2,2 "$TMP/candidates.txt" -o "$TMP/candidates.txt"
	n=$(wc -l < "$TMP/candidates.txt")
	if [ "$n" -gt "$maxc" ]; then
		head -n "$maxc" "$TMP/candidates.txt" > "$TMP/candidates.txt.cap"
		mv "$TMP/candidates.txt.cap" "$TMP/candidates.txt"
		log "候选超过上限, 截取前 $maxc 条"
	fi
}

build_candidates() {
	local mode count
	mode=$(ucigetd test_mode both)
	count=$(ucigetd count 40)
	maxc=$(ucigetd max_candidates 200)
	remark_prefix=$(ucigetd remark_prefix "CF优选")
	fixed_port=$(uciget port)
	: > "$TMP/candidates.tmp"
	if [ "$mode" != "random" ]; then fetch_apis; fi
	if [ "$mode" != "api" ]; then gen_random "$count"; fi
	add_custom
	normalize
	rm -f "$TMP/candidates.tmp"
}

# ---------------- speed test ----------------
# CF 数据中心(机场代码) → 国家编码映射表
IATA_CC='ATL:US BOS:US BUF:US BWI:US CLT:US CMH:US DEN:US DFW:US DTW:US EWR:US FLL:US IAD:US IAH:US IND:US JAX:US JFK:US LAS:US LAX:US LGA:US MCI:US MDW:US MEM:US MIA:US MKE:US MSP:US MSY:US ORD:US PDX:US PHX:US PIT:US RDU:US SAN:US SEA:US SFO:US SJC:US SLC:US STL:US TPA:US TUS:US OKC:US OMA:US AUS:US YUL:CA YVR:CA YWG:CA YYC:CA YYZ:CA YOW:CA YQB:CA MEX:MX GDL:MX MTY:MX CUN:MX GRU:BR GIG:BR EZE:AR SCL:CL BOG:CO LIM:PE PTY:PA SJO:CR SDQ:DO UIO:EC GYE:EC MVD:UY CCS:VE LHR:GB LGW:GB MAN:GB EDI:GB BHX:GB GLA:GB DUB:IE SNN:IE CDG:FR ORY:FR MRS:FR NCE:FR FRA:DE MUC:DE DUS:DE HAM:DE BER:DE CGN:DE STR:DE AMS:NL BRU:BE LUX:LU ZRH:CH GVA:CH VIE:AT MAD:ES BCN:ES VLC:ES AGP:ES LIS:PT OPO:PT MXP:IT FCO:IT LIN:IT VCE:IT NAP:IT BGY:IT ATH:GR WAW:PL KRK:PL GDN:PL WRO:PL PRG:CZ BTS:SK BUD:HU OTP:RO SOF:BG ZAG:HR LJU:SI BEG:RS KBP:UA HEL:FI ARN:SE GOT:SE OSL:NO CPH:DK KEF:IS TLL:EE RIX:LV VNO:LT IST:TR SAW:TR TLV:IL LCA:CY MLA:MT DXB:AE SHJ:AE AUH:AE RUH:SA JED:SA DOH:QA KWI:KW MCT:OM BAH:BH AMM:JO JNB:ZA CPT:ZA DUR:ZA LOS:NG NBO:KE ACC:GH DSS:SN CAI:EG CMN:MA TUN:TN ADD:ET DAR:TZ EBB:UG ABJ:CI ALG:DZ DEL:IN BOM:IN BLR:IN MAA:IN HYD:IN CCU:IN AMD:IN COK:IN LKO:IN KHI:PK ISB:PK LHE:PK DAC:BD CMB:LK KTM:NP RGN:MM BKK:TH SGN:VN HAN:VN PNH:KH KUL:MY SIN:SG CGK:ID DPS:ID SUB:ID MNL:PH CEB:PH HKG:HK PEK:CN PVG:CN CAN:CN TPE:TW KHH:TW NRT:JP HND:JP KIX:JP FUK:JP OKA:JP CTS:JP NGO:JP ICN:KR GMP:KR PUS:KR SYD:AU MEL:AU BNE:AU PER:AU ADL:AU CBR:AU AKL:NZ WLG:NZ NAN:FJ TBS:GE GYD:AZ EVN:AM ALA:KZ TAS:UZ'

# 机场代码 → 国家码
cc_of_iata() {
	echo "$IATA_CC" | tr ' ' '\n' | awk -F: -v c="$1" '$1==c{print $2}' | head -1
}

# 从响应头提取 cf-ray 机场代码
cfray_iata() {  # $1 = header 文件
	grep -i '^cf-ray:' "$1" 2>/dev/null | tail -1 | sed 's/.*-\([A-Z][A-Z][A-Z]\)\r\?$/\1/'
}

# 按 remark_mode 生成备注: country=国家码 / both=国家码-原备注 / prefix=原备注
build_remark() {  # $1=原备注 $2=国家码
	local mode
	mode=$(ucigetd remark_mode country)
	case "$mode" in
		country) [ -n "$2" ] && echo "$2" || echo "$1" ;;
		both)    [ -n "$2" ] && echo "$2-$1" || echo "$1" ;;
		*)       echo "$1" ;;
	esac
}

test_one() {
	local idx=$1 raw=$2 ip rest port remark out code conn speed lat_ms spd_kb hdrf
	ip=${raw%%:*}
	rest=${raw#*:}
	port=${rest%%#*}
	remark=${raw#*#}
	[ "$remark" = "$raw" ] && remark=""
	hdrf="$TMP/results/${idx}.hdr"
	if [ "$BYPASS" = "nobody" ]; then
		out=$(su -s /bin/ash nobody -c "/usr/sbin/curl -s -4 --noproxy '*' --http1.1 --connect-timeout ${CT} --max-time ${MT} -o /dev/null -w '%{http_code} %{time_connect} %{speed_download}' -D '$hdrf' --resolve speed.cloudflare.com:${port}:${ip} 'https://speed.cloudflare.com:${port}/__down?bytes=${BYTES}'" 2>/dev/null)
	else
		out=$(/usr/sbin/curl -s -4 --noproxy '*' --http1.1 --connect-timeout "${CT}" --max-time "${MT}" -o /dev/null -w '%{http_code} %{time_connect} %{speed_download}' -D "$hdrf" --resolve "speed.cloudflare.com:${port}:${ip}" "https://speed.cloudflare.com:${port}/__down?bytes=${BYTES}" 2>/dev/null)
	fi
	code=$(echo "$out" | awk '{print $1}')
	conn=$(echo "$out" | awk '{print $2}')
	speed=$(echo "$out" | awk '{print $3}')
	[ -z "$code" ] && code=000
	[ -z "$conn" ] && conn=0
	[ -z "$speed" ] && speed=0
	echo -e "${raw}\t${code}\t${conn}\t${speed}" > "$TMP/results/${idx}.txt"
	if [ "$code" = "200" ]; then
		lat_ms=$(awk -v c="$conn" 'BEGIN{printf "%d", c*1000}')
		spd_kb=$(awk -v s="$speed" 'BEGIN{printf "%.0f", s/1024}')
		log "OK   ${raw}  延迟=${lat_ms}ms 速度=${spd_kb}KB/s"
	else
		log "FAIL ${raw}  (code=${code})"
	fi
}

run_tests() {
	local par idx=0 n=0 line
	par=$(ucigetd parallel 4)
	[ "$par" -lt 1 ] 2>/dev/null && par=1
	while IFS= read -r line; do
		idx=$((idx + 1))
		test_one "$idx" "$line" &
		echo $! >> "$TMP/pids"
		n=$((n + 1))
		if [ $((n % par)) -eq 0 ]; then wait; fi
	done < "$TMP/candidates.txt"
	wait
}

aggregate() {
	local top ml ms mode bytes ml_s ms_b nres raw ip rest port rem cc newline n
	top=$(ucigetd top 10)
	ml=$(ucigetd max_latency 500)
	ms=$(ucigetd min_speed 0)
	mode=$(ucigetd test_mode both)
	bytes=$(ucigetd test_bytes 5242880)
	ml_s=$(awk -v ml="$ml" 'BEGIN{printf "%.4f", ml/1000}')
	ms_b=$(awk -v ms="$ms" 'BEGIN{printf "%.0f", ms*125000}')
	if [ "$mode" = "latency" ] || [ "$bytes" = "0" ]; then
		awk -F'	' -v ml="$ml_s" '($2==200 && $3>0 && $3<=ml){print}' "$TMP"/results/*.txt 2>/dev/null \
			| sort -k3 -n | head -n "$top" > "$TMP/result.raw"
	else
		awk -F'	' -v ml="$ml_s" -v ms="$ms_b" '($2==200 && $3>0 && $3<=ml && $4>=ms){print}' "$TMP"/results/*.txt 2>/dev/null \
			| sort -k4 -nr | head -n "$top" > "$TMP/result.raw"
	fi
	# 逐行重写备注为 IP 落地国家编码 (cf-ray)
	: > "$TMP/result.txt"
	n=0
	while IFS= read -r line; do
		raw=${line%%$'	'*}
		ip=${raw%%:*}
		rest=${raw#*:}
		port=${rest%%#*}
		rem=${raw#*#}
		[ "$rem" = "$raw" ] && rem=""
		# 定位该节点的 header 文件 (results/<idx>.hdr)
		idx=$(grep -lF "$raw" "$TMP"/results/*.txt 2>/dev/null | head -1 | sed 's|.*/||; s|\.txt$||')
		cc=""
		if [ -n "$idx" ] && [ -f "$TMP/results/${idx}.hdr" ]; then
			cc=$(cc_of_iata "$(cfray_iata "$TMP/results/${idx}.hdr")")
		fi
		newline="$(build_remark "$rem" "$cc")"
		echo "${ip}:${port}#${newline}" >> "$TMP/result.txt"
		n=$((n + 1))
	done < "$TMP/result.raw"
	rm -f "$TMP/result.raw"
	nres=$(wc -l < "$TMP/result.txt")
	log "===== 完成: 输出 $nres 个最优节点 (备注=IP落地国家编码) ====="
}

# ---------------- update check ----------------
# 版本号规范化: 去 v 前缀和 -release 后缀
ver_norm() { echo "$1" | sed 's/^v//; s/-.*//'; }

# $1 > $2 → exit 0; 否则 exit 1
ver_gt() {
	local a b
	a=$(ver_norm "$1"); b=$(ver_norm "$2")
	[ "$a" = "$b" ] && return 1
	echo "$a $b" | awk '{
		split($1,x,"."); split($2,y,".");
		for (i=1; i<=4; i++) {
			xi=(x[i]==""?0:x[i])+0; yi=(y[i]==""?0:y[i])+0;
			if (xi>yi) exit 0;
			if (xi<yi) exit 1;
		}
		exit 1;
	}'
}

installed_version() {
	awk '/^Package: luci-app-cfipopt$/{f=1} f&&/^Version:/{print $2; exit}' /usr/lib/opkg/status 2>/dev/null
}

cmd_check_update() {
	local installed latest url available now last loc tag
	# 手动检查/更新时强制绕过缓存
	[ "$1" = "force" ] && rm -f "$TMP/update_check_ts"
	installed=$(installed_version)
	[ -z "$installed" ] && installed="unknown"
	now=$(date +%s)
	last=$(cat "$TMP/update_check_ts" 2>/dev/null || echo 0)
	# 1 小时缓存; 用 HTML 重定向取最新 tag, 不消耗 GitHub API 配额
	if [ ! -f "$TMP/update.json" ] || [ $((now - last)) -ge 3600 ]; then
		loc=$(curl -sL --max-time 10 -o /dev/null -w '%{url_effective}' \
			"https://github.com/jeremy125/luci-app-cfipopt/releases/latest" 2>/dev/null)
		tag=$(echo "$loc" | sed 's|.*/releases/tag/||')
		if [ -n "$tag" ]; then
			printf '{"tag":"%s","version":"%s"}\n' "$tag" "$(echo "$tag" | sed 's/^v//')" > "$TMP/update.json"
			echo "$now" > "$TMP/update_check_ts"
		fi
	fi
	latest=$(grep -o '"version":"[^"]*"' "$TMP/update.json" 2>/dev/null | head -1 | sed 's/.*"version":"//; s/"//')
	tag=$(grep -o '"tag":"[^"]*"' "$TMP/update.json" 2>/dev/null | head -1 | sed 's/.*"tag":"//; s/"//')
	url=""
	[ -n "$tag" ] && url="https://github.com/jeremy125/luci-app-cfipopt/releases/download/${tag}/luci-app-cfipopt_${latest}-1_all.ipk"
	available="false"
	if [ -n "$latest" ] && [ "$installed" != "unknown" ]; then
		if ver_gt "$latest" "$installed"; then
			available="true"
		fi
	fi
	printf '{"installed":"%s","latest":"%s","update_available":%s,"download_url":"%s"}\n' \
		"$installed" "$latest" "$available" "$url" > "$TMP/update_status.json"
	cat "$TMP/update_status.json"
}

cmd_update() {
	# 更新必须强制拉取最新 Release 信息
	cmd_check_update force >/dev/null
	local latest url rc now_ver
	latest=$(grep -o '"latest":"[^"]*"' "$TMP/update_status.json" 2>/dev/null | cut -d'"' -f4)
	url=$(grep -o '"download_url":"[^"]*"' "$TMP/update_status.json" 2>/dev/null | cut -d'"' -f4)
	if [ -z "$url" ]; then
		log "更新失败: 无法获取最新版本信息 (检查网络/GitHub 连通性)"
		echo '{"ok":false,"msg":"无法获取最新版本信息"}'
		return 1
	fi
	echo downloading > "$TMP/update_progress"
	log "开始下载: $url"
	if ! curl -sL --max-time 120 -o /tmp/luci-app-cfipopt-update.ipk "$url" 2>/dev/null; then
		echo failed > "$TMP/update_progress"
		log "下载失败"
		echo '{"ok":false,"msg":"下载失败"}'
		return 1
	fi
	echo installing > "$TMP/update_progress"
	log "开始安装..."
	opkg install /tmp/luci-app-cfipopt-update.ipk > "$TMP/opkg.log" 2>&1
	rc=$?
	rm -f /tmp/luci-app-cfipopt-update.ipk
	now_ver=$(installed_version)
	# 防护: 安装后版本必须 >= 目标版本, 否则视为失败
	if [ $rc -ne 0 ] || { [ -n "$now_ver" ] && ver_gt "$latest" "$now_ver"; }; then
		echo failed > "$TMP/update_progress"
		log "安装失败: 当前 $(installed_version), 目标 $latest (rc=$rc)"
		echo '{"ok":false,"msg":"安装失败, 版本未更新"}'
		return 1
	fi
	echo done > "$TMP/update_progress"
	log "安装成功 ($(installed_version)), 2 秒后重启服务..."
	# 延迟重启, 让当前 RPC 响应先返回
	( sleep 2; /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart ) >/dev/null 2>&1 &
	echo '{"ok":true,"msg":"更新完成, 请刷新页面"}'
}

# ---------------- main ----------------
cmd_run() {
	rm -rf "$TMP/results"; mkdir -p "$TMP/results"
	# nobody (gid 65534) 绕过测速时需遍历 TMP 并写入响应头文件
	chmod 755 "$TMP"
	chmod 777 "$TMP/results"
	rm -f "$TMP/pids"
	echo running > "$TMP/state"

	detect_proxy
	local bm
	bm=$(ucigetd bypass_mode auto)
	BYPASS=none
	if [ "$bm" = "nobody" ]; then
		BYPASS=nobody
	elif [ "$bm" = "auto" ] && grep -q '"bypass":"nobody-gid"' "$TMP/proxy.json" 2>/dev/null; then
		BYPASS=nobody
	fi
	CT=$(ucigetd connect_timeout 3)
	MT=$(ucigetd max_time 8)
	BYTES=$(ucigetd test_bytes 5242880)
	ports_str=$(ucigetd ports "443 2053 2083 2087 2096 8443")
	fixed_port=$(uciget port)

	log "代理检测: $(cat "$TMP/proxy.json" 2>/dev/null)"
	if [ "$BYPASS" = "nobody" ]; then
		log "绕过方式: 已启用 (gid 65534 / nobody 身份直连)"
	else
		log "绕过方式: 未启用 (当前为直连)"
	fi

	build_candidates
	local total
	total=$(wc -l < "$TMP/candidates.txt")
	log "候选节点数: $total"
	if [ "$total" -eq 0 ]; then
		echo "无可用候选节点, 请检查网络或 API 地址" > "$TMP/result.txt"
		echo error > "$TMP/state"
		return 1
	fi

	run_tests
	aggregate
	echo done > "$TMP/state"
}

cmd_start() {
	cmd_stop 2>/dev/null
	mkdir -p "$TMP/results"
	: > "$TMP/log"
	: > "$TMP/pids"
	: > "$TMP/result.txt"
	: > "$TMP/candidates.txt"
	rm -f "$TMP/state" "$TMP/proxy.json" "$TMP/done" "$TMP/exitcode"
	log "===== CF IP 优选测速 开始 ====="
	setsid sh -c "exec $RUN run" >/dev/null 2>&1 &
	echo $! > "$TMP/pid"
	log "后台 PID: $(cat "$TMP/pid")"
}

cmd_stop() {
	local pid p
	pid=$(cat "$TMP/pid" 2>/dev/null)
	[ -n "$pid" ] && kill -TERM -- "-$pid" 2>/dev/null
	[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
	if [ -f "$TMP/pids" ]; then
		while read -r p; do kill -TERM "$p" 2>/dev/null; done < "$TMP/pids"
	fi
	rm -f "$TMP/pids"
	[ -f "$TMP/state" ] && echo stopped > "$TMP/state"
	log "测速已停止"
}

cmd_proxy() {
	mkdir -p "$TMP"
	detect_proxy
	cat "$TMP/proxy.json"
}

case "$1" in
	start) cmd_start ;;
	stop)  cmd_stop ;;
	run)   cmd_run ;;
	proxy) cmd_proxy ;;
	status) [ -f "$TMP/state" ] && cat "$TMP/state" || echo idle ;;
	check_update) cmd_check_update ;;
	update) cmd_update ;;
	*) echo "usage: $0 {start|stop|run|proxy|status|check_update|update}"; exit 1 ;;
esac
