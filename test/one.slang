      local thread = require("slang/thread")
      local output = {}
      local channel = thread.channel.new(5)
      local producer = thread.create(func(){
        for(local i = 0; i < 10; i = i + 1){
          channel:send(i) 
        }
      }) 
      local consumer = thread.create(func(){
        for(true){
          local value = channel:receive()
          append(output, value * value)
        }
      })
      thread.parallel(producer, consumer)
      assert(len(output) == 10, "output should have 10 elements")
      for(local i = 0; i < 10; i = i + 1){
        assert(output[i] == i * i, "output should have the square of the input")
      }