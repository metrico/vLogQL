module main

import os
import json
import flag
import term
import time
import rand
import net.http
import net.websocket
import v.vmod
import strconv
import regex
import strings

struct App {
mut:
	counter string = '0'
	last    string = '0'
	last_ts string = '0'
	diff_ts string = '0'
	api     string = '0'
	query   string = '0'
	limit   int
	start   string = '0'
	end     string = '0'
	labels  bool
	debug   bool
	timer   int
}

struct Response {
mut:
	status string
	data   Data
}

struct Data {
mut:
	res_type string   [json: 'resultType']
	result   []Result
}

struct Result {
mut:
	stream map[string]string
	values [][]string
}

struct Values {
	ts  int
	log string
}

fn fetch_logs(app App) {
	data := http.get_text('$app.api/loki/api/v1/query_range?query=$app.query&limit=$app.limit&start=$app.start&end=$app.end')
	res := json.decode(Response, data) or { exit(1) }
	println('---------- Logs for: $app.query')
	for row in res.data.result {
		if app.labels {
			print(term.gray('Log Labels: '))
			print(term.bold('$row.stream\n'))
		}
		for log in row.values {
			println(log[1])
		}
	}
	return
}

struct Labels {
	status string
	data   []string
}

fn fetch_labels(api string, label string) {
	if label.len_utf8() > 0 {
		data := http.get_text('$api/loki/api/v1/label/$label/values')
		res := json.decode(Labels, data) or { exit(1) }
		println('---------- Values for: $label')
		println(term.bold(res.data.str()))
		return
	} else {
		data := http.get_text('$api/loki/api/v1/labels')
		res := json.decode(Labels, data) or { exit(1) }
		println('---------- Labels:')
		println(term.bold(res.data.str()))
		return
	}
}

fn set_value(s string) ?string {
	if s != '' {
		return s
	}
	return none
}

fn now(diff int) string {
	ts := time.utc()
	subts := ts.unix_time_milli() - (diff * 1000)
	return '${subts}000000'
}

fn now_iso() string {
	mut timestamp := time.now().format_ss_micro().split(' ').join('T') + 'Z'
	return timestamp
}

fn get_rand(len int) string {
	return rand.string_from_set('abcdefghiklmnopqrestuvwzABCDEFGHIKLMNOPQRSTUVWWZX0123456789',
		len)
}

struct Tail {
mut:
	streams []Result
}

fn tail_logs(app App) ? {
	socket := app.api.replace('http', 'ws')
	mut ws := websocket.new_client(socket + '/loki/api/v1/tail?query=' + app.query) ?
	// use on_open_ref if you want to send any reference object
	ws.on_open(fn (mut ws websocket.Client) ? {
		println('---------- Tail Logs')
	})
	// use on_error_ref if you want to send any reference object
	ws.on_error(fn (mut ws websocket.Client, err string) ? {
		eprintln('---------- Tail error: $err')
	})
	// use on_close_ref if you want to send any reference object
	// ws.on_close(fn (mut ws websocket.Client, code int, reason string) ? {
	//	eprintln('---------- Tail closed')
	// })
	// use on_message_ref if you want to send any reference object
	ws.on_message_ref(fn (mut ws websocket.Client, msg &websocket.Message, app &App) ? {
		if msg.payload.len > 0 {
			message := msg.payload.bytestr()
			res := json.decode(Tail, message) or { exit(1) }
			for row in res.streams {
				if app.labels {
					print(term.gray('Log Labels: '))
					print(term.bold('$row.stream\n'))
				}
				for log in row.values {
					println(log[1])
				}
			}
		}
	}, app)

	ws.connect() or { eprintln('error on connect: $err') }

	ws.listen() or { eprintln('error on listen $err') }
	unsafe {
		ws.free()
	}
}

fn canary_logs(mut app App, canary_string string) ? {
	query := '{canary="$canary_string"}'

	socket := app.api.replace('http', 'ws')
	mut ws := websocket.new_client(socket + '/loki/api/v1/tail?query=' + query) ?

	ws.on_open(fn (mut ws websocket.Client) ? {
		println('---------- Tail Canary Logs')
	})
	ws.on_error(fn (mut ws websocket.Client, err string) ? {
		eprintln('---------- Tail error: $err')
	})
	ws.on_message_ref(fn (mut ws websocket.Client, msg &websocket.Message, mut app App) ? {
		if msg.payload.len > 0 {
			diff_ts := now(0).i64() - app.last_ts.i64()
			app.diff_ts = diff_ts.str()
			message := msg.payload.bytestr()
			res := json.decode(Tail, message) or { exit(1) }
			for row in res.streams {
				if app.labels {
					print(term.gray('Log Labels: '))
					print(term.bold('$row.stream\n'))
				}
				for log in row.values {
					println(log[1])
					if log[1] != app.last {
						eprintln('>>>>>>>>>> Out of order log! log=$app.last')
					}
					if log[0] != app.last_ts {
						eprintln('>>>>>>>>>> Out of order timestamp! last_ts=$app.last_ts')
					}
					if app.diff_ts.len > 9 {
						eprintln('>>>>>>>>>> High latency! diff_ts=$app.diff_ts')
					}
				}
			}
		}
	}, app)

	ws.connect() or { eprintln('error on connect: $err') }
	ws.listen() or { eprintln('error on listen $err') }
	unsafe {
		ws.free()
	}
}

fn canary_emitter(mut app App, canary_string string, timer int, count int) ? {
	labels := '{"canary":"$canary_string","type":"canary"}'
	timestamp := now(0)
	mut log := 'ts=$timestamp count=$count type=canary tag=$canary_string delay=$app.diff_ts'
	payload := '{"streams":[{"stream": $labels, "values":[ ["$timestamp", "$log"] ]}]}'
	data := http.post_json('$app.api/loki/api/v1/push', payload) or { exit(1) }
	if data.status_code != 204 {
		eprintln('PUSH error: $data.status_code')
	} else {
		// println('PUSH successful: $data.status_code')
	}
	next := count + 1
	app.counter = (app.counter.int() + 1).str()
	app.last = log
	app.last_ts = timestamp
	// println('Sleeping for $timer seconds...')
	time.sleep(timer * time.second)
	go canary_emitter(mut app, canary_string, timer, next)
}


struct LogRow {
    id string
    ts i64
    labels string
    line string
}

fn export_logs_iteration(app App) i64 {
	data := http.get_text('$app.api/loki/api/v1/query_range?query=$app.query&limit=10000&start=$app.start&end=$app.end')
	res := json.decode(Response, data) or { exit(1) }
	mut rows := []LogRow{len:0, cap:10000}
	for row in res.data.result {
		for log in row.values {
		    ts := strconv.common_parse_int(log[0], 10, 63, false, false) or {0}
		    labels := json.encode(row.stream)
		    id := strconv.v_sprintf('%ld-%s', ts, labels)
		    log_row := LogRow{id: id, ts: ts, labels: labels , line: log[1]}
		    rows << log_row
		}
	}
	rows.sort(a.id > b.id)
	mut last_labels := ''
	mut last_ts := i64(-1)
	if rows.len > 1 {
	    last_ts = rows.pop().ts
	}
	for r in rows {
	    if r.ts == last_ts {
	        continue
	    }
	    if last_labels != r.labels {
	        println("\n" + r.labels)
	        last_labels = r.labels
	    }
	    ts := time.unix(r.ts / 1000000000)
	    time_sec := ts.custom_format('YYYY-MM-DDTHH:mm:ss')
	    time_ofs := ts.custom_format('ZZZ')
	    ns := r.ts % 1000000000
	    line := r.line.trim('\n')
	    strconv.v_printf('  %s.%09ld%s %s\n', time_sec, ns, time_ofs, line)

	}
	return last_ts
}

fn export_logs(app App) {
    mut m_app := app
    mut last_ts := i64(0)
    for last_ts != -1 {
        last_ts = export_logs_iteration(m_app)
        m_app.end = strconv.v_sprintf('%ld', last_ts)
        println(last_ts)
    }
}

struct LogsImporter {
mut:
    stream_map map[string][][]string
    labels string
    log_time string
    log_line string
    size i64
    eof bool
pub mut:
    app App
}

fn (l LogsImporter)has_key(key string) bool {
    m := l.stream_map[key] or {
        return false
    }
    return true || m.len >= 0
}

fn (mut l LogsImporter)add_line() {
    if l.log_time != '' {
        if l.has_key(l.labels) {
            l.stream_map[l.labels] << [l.log_time, l.log_line]
        } else {
            l.stream_map[l.labels] = [[l.log_time, l.log_line]]
        }
        l.size = l.size + l.log_line.len
        l.maybe_send()
    }
}

fn (mut l LogsImporter)maybe_send() {
    if l.size >= 10 * 1024 * 1024 {
        l.send()
    }
}

fn (mut l LogsImporter) send() {
    mut builder := strings.new_builder(15*1024 * 1024)
    mut i := 0
    builder.write_string('{"streams":[')
    for k, v in l.stream_map {
        if i > 0 {
            builder.write_string(',')
        }
        builder.write_string('{"stream":' + k + ',"values":')
        builder.write_string(json.encode(v))
        builder.write_string('}')
        i++
    }
    builder.write_string(']}')
    resp := http.post_json(strconv.v_sprintf('%s/loki/api/v1/push', l.app.api), builder.str()) or {
        panic(err)
    }
    if !resp.status().is_success() {
        status := resp.status().int()
        bytes := resp.bytestr()
        panic(strconv.v_sprintf('[%d] %s', status, bytes))
    }
    l.size = 0
    l.stream_map = map[string][][]string
}

fn (mut l LogsImporter)read_line() string {
    return os.input_opt('') or {
        l.eof = true
        return ''
    }
}

fn (mut l LogsImporter)import_logs(app App) {
    mut new_stream := regex.regex_opt('^\\{.+$') or {
        println('invalid stream re')
        panic(err)
        return
    }
    mut new_line := regex.regex_opt(r"^  (?P<time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}).(?P<ns>\d{0,9})(?P<ofs>[+\-][0-9:]+) (?P<line>.+)$") or {
        println('invalid line re')
        panic(err)
        return
    }
    l.eof = false
    for true {
        line := l.read_line()
        if l.eof {
            break
        }
        if line == '' {
            continue
        }
        if new_stream.matches_string(line) {
            l.add_line()
            l.labels = line
            l.log_time = ''
            l.log_line = ''
            continue
        }
        if new_line.matches_string(line) {
            l.add_line()
            rfc3339 := new_line.get_group_by_name(line, 'time') + new_line.get_group_by_name(line, 'ofs')
            t := time.parse_rfc3339(rfc3339) or {
                println('can\'t parse time: ' + rfc3339)
                continue
            }
            ns := strconv.common_parse_int(new_line.get_group_by_name(line, 'ns'), 10, 63, false, false) or {0}
            ts := t.unix_time() * 1000000000 + ns
            l.log_time = strconv.v_sprintf('%ld', ts)
            l.log_line = new_line.get_group_by_name(line, 'line')
            continue
        }
        l.log_line += '\n' + line
    }
    l.send()
}



fn main() {
	mut app := &App{}
	app.counter = (0).str()
	mut fp := flag.new_flag_parser(os.args)
	vm := vmod.decode(@VMOD_FILE) or { panic(err.msg()) }
	fp.application('$vm.name')
	fp.description('$vm.description')
	fp.version('$vm.version')
	fp.skip_executable()

	env_limit := set_value(os.getenv('LOGQL_LIMIT')) or { '5' }
	logql_limit := fp.int('limit', `l`, env_limit.int(), 'logql query limit [LOGQL_LIMIT]')
	app.limit = logql_limit

	env_api := set_value(os.getenv('LOGQL_API')) or { 'http://localhost:3100' }
	logql_api := fp.string('api', `a`, env_api, 'logql api [LOGQL_API]')
	app.api = logql_api

	env_query := set_value(os.getenv('LOGQL_QUERY')) or { '' }
	logql_query := fp.string('query', `q`, env_query, 'logql query [LOGQL_QUERY]')
	app.query = logql_query

	logql_labels := fp.bool('labels', `t`, false, 'get labels')
	logql_label := fp.string('label', `v`, '', 'get label values')
	app.labels = logql_labels

	logql_import := fp.bool('import', `t`, false, 'import exported log lines from stdin')
    logql_export := fp.bool('export', `t`, false, 'export log lines to stdout')

	logql_start := fp.string('start', `s`, now(3600), 'start nanosec timestamp')
	logql_end := fp.string('end', `e`, now(0), 'end nanosec timestamp')
	app.start = logql_start
	app.end = logql_end

	logql_tail := fp.bool('tail', `x`, false, 'tail mode')

	logql_canary := fp.bool('canary', `c`, false, 'canary mode')
	env_canary_label := set_value(os.getenv('CANARY_LABEL')) or { '' }
	env_canary_timer := set_value(os.getenv('CANARY_TIMER')) or { '10' }

	fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		return
	}

	if logql_import {
    	mut l := LogsImporter{app: app}
    	l.import_logs(app)
    } else if logql_query.len_utf8() > 0 {
		if logql_tail {
			tail_logs(app) or { exit(1) }
		} else if logql_canary {
			mut tag := env_canary_label
			tag = get_rand(12)
			tag = 'canary_' + tag
			go canary_emitter(mut app, tag, env_canary_timer.int(), 0)
			canary_logs(mut app, tag) or { exit(1) }
		} else if logql_export {
		    export_logs(app)
		} else {
			fetch_logs(app)
		}
		return
	} else if logql_canary {
		mut tag := env_canary_label
		if env_canary_label.len < 1 {
			tag = get_rand(12)
		}
		tag = 'canary_' + tag
		go canary_emitter(mut app, tag, env_canary_timer.int(), 0)
		canary_logs(mut app, tag) or { exit(1) }
	} else if logql_labels {
		fetch_labels(logql_api, '')
		return
	} else if logql_label.len_utf8() > 0 {
		fetch_labels(logql_api, logql_label)
		return
	} else {
		println(fp.usage())
		return
	}
}
