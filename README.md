# Birdler

An ultra-minimal Bird.com Sender for Erlang

## Configure it

```erlang
[{birdler, [
 {api_key, "MY_API_KEY"}
]}].
```

## Start The App

Start the app:

```erlang
sparkler:start()
```

## Send mail

```erlang
birdler:send(#{from=>"from@email.com",
               to=>"to@email.com",
               subject=>"Subject",
               html=>"HTML Message"}).
```

# License

MIT LICENSE

Copyright &copy; 2026 [Jesse Gumm](http://jessegumm.com)
