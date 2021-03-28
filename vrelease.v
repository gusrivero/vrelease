// vi: ft=vlang

/*
	The person who associated a work with this deed has dedicated the work to the
	public domain by waiving all of his or her rights to the work worldwide under
	copyright law, including all related and neighboring rights, to the extent
	allowed by law.

	You can copy, modify, distribute and perform the work, even for commercial
	purposes, all without asking permission.

	AFFIRMER OFFERS THE WORK AS-IS AND MAKES NO REPRESENTATIONS OR WARRANTIES OF
	ANY KIND CONCERNING THE WORK, EXPRESS, IMPLIED, STATUTORY OR OTHERWISE,
	INCLUDING WITHOUT LIMITATION WARRANTIES OF TITLE, MERCHANTABILITY, FITNESS
	FOR A PARTICULAR PURPOSE, NON INFRINGEMENT, OR THE ABSENCE OF LATENT OR OTHER
	DEFECTS, ACCURACY, OR THE PRESENT OR ABSENCE OF ERRORS, WHETHER OR NOT
	DISCOVERABLE, ALL TO THE GREATEST EXTENT PERMISSIBLE UNDER APPLICABLE LAW.

	For more information, please see
	<http://creativecommons.org/publicdomain/zero/1.0/>
*/

module main

import os
import json
import term
import time
import encoding.base64

import cli { Command, Flag }
import net.http { Method, Request, Response }

/* data structures */

enum Protocol {
	http
	https
	ssh
}

struct GitRemote {
	protocol Protocol [required]

	uri  string [required]
	user string [required]
	repo string [required]
}

struct ReleaseBody {
	target_commitish string [required]
	tag_name         string [required]
	name             string [required]
	body             string [required]
	draft            bool   [required]
	prerelease       bool   [required]
}

/* utils */

fn emph(txt string) string {
	return term.green(txt)
}

fn info(txt string) {
	print(term.bright_blue('=> ') + txt + '\n')
}

fn errmsg(txt string) string {
	return term.bold(term.bright_red('ERROR: ')) + txt
}

/* running "phases" */

fn start_msg(now time.Time, md map[string]string) {
	println('')
	println(term.bold("${md['program_name']} ${md['program_version']} ${md['target_kernel']}/${md['target_arch']}"))
	println(term.gray('program has started @ ${now.str()}'))
	println('')
}

fn get_token() ?string {
	key := 'VRELEASE_GITHUB_TOKEN'
	env := os.environ()

	if key in env { return env[key] }
	panic(errmsg('environment variable $key is undefined'))
}

fn get_remote_info() ?GitRemote {
	res := os.execute_or_panic('git remote get-url --all origin')
	out := res.output.trim_space().split('\n')
	uri := out[0]

	mut protocol := Protocol.ssh
	if uri.starts_with('http://') { protocol = Protocol.http }
	if uri.starts_with('https://') { protocol = Protocol.https }

	xtract := fn (p Protocol, uri string) (string, string) {
		mf := errmsg('malformed remote git URI; got "$uri"')

		if !uri.contains('/') { panic(mf) }

		mut user := ''
		mut repo := ''

		if p == Protocol.ssh {
			if !uri.contains(':') { panic(mf) }

			mut segs := uri.split(':')
			if segs.len != 2 { panic(mf) }

			segs = segs[1].split('/')
			if segs.len != 2 { panic(mf) }

			user = segs[0]
			repo = segs[1]

		}
		else {
			segs := uri.split('/')
			if segs.len != 5 { panic(mf) }

			user = segs[3]
			repo = segs[4]
		}

		return user, repo[0 .. repo.len - 4] // removes ".git" from the repo name
	}

	user, repo := xtract(protocol, uri)
	return GitRemote{protocol, uri, user, repo}
}

fn get_repo_changelog(user string, repo string) ?map[string]string {
	nt := errmsg('no tags found')

	mut res := os.execute_or_panic('git tag --sort=committerdate')
	mut tags := res.output.split('\n')

	if tags.len <= 1 { panic(nt) }
	tags.pop()

	if tags[0].trim_space() == '' { panic(nt) }
	last_ref := tags[tags.len - 1].trim_space()

	mut sec_last_ref := 'master'
	if tags.len >= 2 {
		sec_last_ref = tags[tags.len - 2].trim_space()
	}

	info('generating changelog from ${emph(sec_last_ref)} to ${emph(last_ref)}')
	res = os.execute_or_panic('git log --pretty=oneline ${sec_last_ref}..${last_ref}')

	mut logs := res.output.split('\n')
	if logs.len <= 1 { panic('no entries') }
	logs.pop()

	mut changelog := ''
	for i := 0; i < logs.len; i++ {
		log := logs[i]

		sha := log[0 .. 40]
		msg := log[41 .. log.len]

		commit_url := 'https://github.com/$user/$repo/commit'
		changelog += '<li><a href="$commit_url/$sha"><code>${sha[0 .. 7]}</code></a> $msg</li>'
	}

	changelog = '<h1>Changelog</h1><ul>$changelog</ul>'
	return map{ 'content': changelog, 'tag': last_ref }
}

fn create_release(remote GitRemote, token string, changelog map[string]string) ?Response {
	payload := ReleaseBody{
        target_commitish: 'master'
        tag_name:         changelog['tag']
        name:             changelog['tag']
        body:             changelog['content']
        draft:            false
        prerelease:       false
	}

	mut req := Request{
		method: Method.post,
		url:    'https://api.github.com/repos/$remote.user/$remote.repo/releases',
		data:   json.encode(payload)
	}

	auth_h_v := 'Basic ' + base64.encode_str('$remote.user:$token')
	req.add_header('Accept', 'application/vnd.github.v3+json')
	req.add_header('Authorization', auth_h_v)

	res := req.do() or { panic(errmsg('error while making request; got "$err.msg"')) }
	return res
}

struct Cli {
pub mut:
	cmd Command
}

fn (mut c Cli) is_set(flag string) bool {
	return c.cmd.flags.get_bool(flag) or { false }
}

fn (mut c Cli) act() {
	c.cmd.setup()
	c.cmd.parse(os.args)

	if c.is_set('help') {
		c.cmd.execute_help()
		exit(0)
	}

	if c.is_set('version') {
		println(c.cmd.version)
		exit(0)
	}
}

fn build_cli(md map[string]string) Cli {
	mut cmd := Command{
		name:            md['program_name']
		description:     md['program_description']
		version:         md['program_version']
		disable_help:    true
		disable_version: true
	}

	cmd.add_flag(Flag{
		flag:        .bool
		name:        'debug'
		abbrev:      'd'
		description: 'enables the debug mode'
	})

	cmd.add_flag(Flag{
		flag:        .bool
		name:        'no-color'
		abbrev:      'n'
		description: 'disables output with colors (useful on non-compliant shells)'
	})

	cmd.add_flag(Flag{
		flag:        .string
		name:        'attach'
		abbrev:      'a'
		description: 'attaches (uploads) a file to the release'
	})

	cmd.add_flag(Flag{
		flag:          .int
		name:          'limit'
		abbrev:        'l'
		default_value: ['-1']
		description:   'sets a limit to the amount of commits on the changelog'
	})

	cmd.add_flag(Flag{
		flag:        .bool
		name:        'help'
		abbrev:      'h'
		description: 'prints help information'
	})

	cmd.add_flag(Flag{
		flag:        .bool
		name:        'version'
		abbrev:      'v'
		description: 'prints version information'
	})

	return Cli{ cmd }
}

fn main() {
	meta_d := get_meta_d()

	mut cli := build_cli(meta_d)
	cli.act()

	started_at := time.now()
	start_msg(started_at, meta_d)

	gh_token := get_token() or { panic(err.msg) }
	remote := get_remote_info() or { panic(err.msg) }

	info('executing on repository ${emph(remote.repo)} of user ${emph(remote.user)}')
	changelog := get_repo_changelog(remote.user, remote.repo) or { panic(err.msg) }

	info('creating release')
	release_res := create_release(remote, gh_token, changelog) or { panic(err.msg) }

	if release_res.status_code != 201 {
		panic(errmsg('failed with code $release_res.status_code; << $release_res.text >>'))
	}

	duration := time.now() - started_at
	info('done; took ${emph(duration.milliseconds().str() + "ms")}')
}
