# Rollout::UI

A Rack-mountable UI for the [rollout](https://github.com/fetlife/rollout) gem.

![Index Page](./screenshot_index.png)
<!-- ![Feature Page](./screenshot_show.png) -->

## Usage with Rails

Add it to your application's Gemfile:

```ruby
gem "rollout", "~> 3.1"
gem "rollout-redis-adapter", "~> 0.1"
gem "rollout-ui"
```

`rollout-ui` 0.9+ requires Rollout 3.1 or later within 3.x. It works with any
Rollout adapter; Redis applications also need `rollout-redis-adapter`.

Mount the Rack app:

```ruby
Rails.application.routes.draw do
  mount Rollout::UI::Web.new => "/admin/rollout"

  # ...
end
```

Configure your Rollout instance in `routes.rb` or an initializer:

```ruby
Rollout::UI.configure do
  instance { $rollout }
end
```

## Authentication

Protect the Rails mount with a constraint. For example, with Devise:

```ruby
class AdminConstraint
  def self.matches?(request)
    id = request.session["warden.user.user.key"].try(:[], 0).try(:[], 0)
    return false if id.blank?

    user = User.find_by(id: id)
    user&.admin?
  end
end

Rails.application.routes.draw do
  mount Rollout::UI::Web.new => "/admin/rollout", constraints: AdminConstraint

  # ...
end
```

## Nickname user selector

Configure **both** callbacks below to replace the user ID field with a searchable
multi-select. Your application supplies the queries; the UI displays nicknames
and Rollout stores user IDs. This example uses Rails and PostgreSQL:

```ruby
Rollout::UI.configure do
  instance { $rollout }

  user_search do |query, limit|
    prefix = User.sanitize_sql_like(query.downcase) + "%"
    User.where("lower(nickname) LIKE ?", prefix)
      .limit(limit)
      .pluck(:id, :nickname)
      .map { |id, nickname| { id: id.to_s, nickname: nickname } }
  end

  user_lookup do |ids|
    User.where(id: ids)
      .pluck(:id, :nickname)
      .map { |id, nickname| { id: id.to_s, nickname: nickname } }
  end
end
```

Both callbacks return arrays of hashes with `id` and `nickname` keys (symbols or
strings). `user_search` receives a trimmed nickname query and a result limit.
`user_lookup` receives a batch of selected or historical user IDs as strings;
omit missing accounts. Apply your account visibility rules in both callbacks.

Search defaults to **3 characters** and **20 results**, with a 300 ms debounce.
Override these settings inside the same configuration block:

```ruby
user_search_min_length { 3 }
user_search_limit { 20 }
```

For large directories, use **indexed nickname-only prefix matching** and apply
the limit in the database. Escape wildcards as above; avoid loading all users or
running unindexed `%contains%` queries. A matching index for this example is:

```sql
CREATE INDEX CONCURRENTLY users_nickname_prefix_idx
  ON users (lower(nickname) text_pattern_ops);
```

Check the query plan against your schema and collation. The selector supports
keyboard navigation and preserves selections if a lookup fails. Without
JavaScript, the ID field remains usable. Features with more than 150 selected
users show only a count.

## Logging

Enable logging on your Rollout instance to display change history:

```ruby
require "redis"
require "rollout"
require "rollout/adapters/redis"

$redis = Redis.new
$rollout = Rollout.new(
  adapter: Rollout::Adapters::Redis.new($redis),
  logging: { history_length: 100, global: true },
)
```

Configure `actor` and `actor_url` to attribute changes. For example, with Devise:

```ruby
Rollout::UI.configure do
  instance { $rollout }
  actor { current_user&.nickname }
  actor_url { |actor| "/#{actor}" }
end
```

When using a Rollout version and adapter that support event-aware deletion,
deletions appear in the overview history with the configured actor. This
requires global logging (`global: true`); adapters without event-aware deletion
retain the previous behavior and do not add a deletion event.

With `user_lookup` configured, feature and overview history display current
nicknames while audit events retain IDs. History resolves up to 150 additional
distinct IDs per page; missing accounts, failed lookups, and IDs beyond that limit
use ID-based labels.

## API Endpoints

Send `Accept: application/json` to the index or feature route for JSON responses.
The index also accepts filters such as `/admin/rollout?user=123` and
`/admin/rollout?group=developers`.

When both nickname callbacks are configured, `GET /users/search?q=alice`
(relative to the mount) returns `{"users":[{"id":"123","nickname":"alice"}]}`.
It uses the mount's authentication, caps results server-side, and sends
`Cache-Control: no-store`. Queries below the configured minimum return an empty
list without calling `user_search`. Queries are limited to 100 characters;
configured minimum lengths and result limits are bounded to 1–100.

## Host Header Validation

When mounted in Rails, requests pass through Rails' `config.hosts` checks. The gem
performs no additional Host header validation.

For standalone use (e.g. `rackup`), configure authentication and host validation
through middleware such as
[`Rack::Protection::HostAuthorization`](https://github.com/sinatra/sinatra/tree/main/rack-protection#host-authorization-api)
or a reverse proxy that only forwards trusted hosts.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/fetlife/rollout-ui.

### Development Setup

This project uses [mise](https://mise.jdx.dev/) for managing development tools.

Install mise if you haven't already:

```sh
curl https://mise.run | sh
```

Then install the required tools and dependencies:

```sh
mise install
bundle install
```

To run this project for development in isolation:

```sh
bundle exec rerun rackup
```

And visit [http://localhost:9292/](http://localhost:9292/).

To use a different Redis connection:

```sh
REDIS_HOST=localhost REDIS_PORT=6379 REDIS_DB=10 bundle exec rerun rackup
```

### Releasing

1. Bump version: `rake version:patch` (or `minor`/`major`)
2. Commit and tag: `git commit -am "Bump version" && git tag v0.7.3`
3. Push: `git push origin master --tags`

The GitHub Actions workflow will automatically publish to RubyGems when tags are pushed.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
