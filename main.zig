// © 2025 John Emanuelsson
// File created 2025-07-07 11:39:00 CEST
const std = @import("std");
const time = std.time;
const debug = std.debug;
const fs = std.fs;
const ArrayList = std.ArrayList;
const zlua = @import("zlua");
const Lua = zlua.Lua;
const assert = std.debug.assert;
const os = std.os;
const Thread = std.Thread;
const Semaphore = Thread.Semaphore;
const Allocator = std.mem.Allocator;

fn minus_one(comptime T:type) T {return -%@as(T, 1);}
// pub fn BlockingMpmc(size: u32) type {
//   return struct {
//     queue: Mpmc(size),
//     producer_sem: std.Thread.Semaphore,
//     consumer_sem: std.Thread.Semaphore,

//     pub fn init() @This() {
//       return struct {
//         .queue = Mpmc(size).init(),
//         .producer_sem = .{.permits = size},
//         .consumer_sem = .{},
//       };
//     }
//     pub fn deinit(self: *@This()) void {
//       self.producer_sem.deinit();
//       self.consumer_sem.deinit();
//       self.queue.deinit();
//     }

//     pub fn bgn(self: *@This(), comptime push: bool) u32 {
//       const sem = if (push) self.producer_sem else self.consumer_sem;
//       sem.wait();
//       self.queue.bgn(push);
//     }
//     pub fn end(self: *@This(), idx: u32, comptime push: bool) void {
//       self.queue.end(idx, push);
//       const sem = if (push) self.consumer_sem else self.producer_sem;
//       sem.post();
//     }
//     pub fn psh_bgn(self: *@This()) u32            {return self.bgn(     true );}
//     pub fn psh_end(self: *@This(), idx: u32) void {return self.end(idx, true );}
//     pub fn pop_bgn(self: *@This()) u32            {return self.bgn(     false);}
//     pub fn pop_end(self: *@This(), idx: u32) void {return self.end(idx, false);}
//   };
// }



pub fn Mpmc(size: u32) type {
  const num_slots = (size+63) / 64;
  const num_lines = (size+511) / 512;
  const mask = num_slots - 1;
  assert(num_slots >= 2);
  assert(mask & num_slots == 0);

  return struct {
    head: std.atomic.Value(u64),
    _padding2: [56]u8,
    tail: std.atomic.Value(u64),
    _padding3: []u8,
    bitset: [num_slots]std.atomic.Value(u64),

    pub fn init() @This() {
      var r: @This() = undefined;
      r.head.store(0, .seq_cst);
      r.tail.store(0, .seq_cst);
      for (0..num_slots) |i| {
        r.bitset[i].store(0, .seq_cst);
      }
      return r;
    }
    pub fn deinit(self: *@This()) void {
      const h = self.head.fetch(.seq_cst);
      const t = self.tail.fetch(.seq_cst);
      assert(h == t);
      for (0..num_slots) |i| {
        assert(self.bitset[i].fetch(.seq_cst) == 0);
      }
      assert(self.head.fetch(.seq_cst) == h);
      assert(self.tail.fetch(.seq_cst) == t);
    }

    pub fn bgn(self: *@This(), comptime push: bool) u32 {
      const A = if (push) &self.head else &self.tail;
      const B = if (push) &self.tail else &self.head;
 
      while(true) {
        const a = A.load(.acquire);
        const b = B.load(.acquire);

        const a2 = a + 1;
        
        const idx = a & mask;
        const line_idx = idx % num_lines;
        const slot_idx = (idx / num_lines) / 64 + line_idx * 8;
        const bit_idx: u6  = @truncate((idx / num_lines) % 64);
        
        const a3 = if (push) a2 else a2 + 1;
          // debug.print("_{} {} {} {}\n", .{a, b, a2, a3});
        if (a3 & mask == b & mask) {
          // debug.print("A\n", .{});
          return ~@as(u32, 0);
        }
        if ((self.bitset[slot_idx].load(.acquire) & (@as(u64, 1) << bit_idx) != 0) == push) {
          if (A.load(.seq_cst) != a) { // A was changed, so let's try again
            std.atomic.spinLoopHint();
            continue;
          }
          return ~@as(u32, 0); // Otherwise: A wasn't changed, because bit is (un)set, we can't acquire this index until the owning thread is done.
        }
        if (A.cmpxchgWeak(a, a2, .acquire, .acquire) == null) {
          return @truncate(idx);
        }
        std.atomic.spinLoopHint();
      }
    }
    pub fn end(self: *@This(), idx: u32, comptime push: bool) void {
      assert(idx != ~@as(u32, 0));
      const line_idx = idx % num_lines;
      const slot_idx = (idx / num_lines) / 64 + line_idx * 8;
      const bit_idx: u6  = @truncate((idx / num_lines) % 64);
      // assert(((self.bitset[slot_idx].load(.seq_cst)) & (@as(u64, 1) << bit_idx) == 0) == push);

      const prev_bit: u1 = self.bitset[slot_idx].bitToggle(bit_idx, .release);
      assert((prev_bit == 0) == push);
      // const bit: u64 = @as(u64, 1) << bit_idx;
      // if (push) {
      //   self.bitset[slot_idx].fetchOr ( bit, .release);
      // } else {
      //   self.bitset[slot_idx].fetchAnd(~bit, .release);
      // }
    }
    pub fn psh_bgn(self: *@This()) u32            {return self.bgn(     true );}
    pub fn psh_end(self: *@This(), idx: u32) void {return self.end(idx, true );}
    pub fn pop_bgn(self: *@This()) u32            {return self.bgn(     false);}
    pub fn pop_end(self: *@This(), idx: u32) void {return self.end(idx, false);}
  };
}
test "mpmc single threaded" {
  var queue = Mpmc(1024).init();
  defer queue.deinit();

  // Push and pop once
  const x = queue.psh_bgn();
  assert(x == 0);
  assert(queue.pop_bgn() == ~@as(u32, 0));
  queue.psh_end(x);
  assert(queue.pop_bgn() == x);
  queue.pop_end(x);

  assert(queue.head.fetch(.seq_cst) == 1);
  assert(queue.tail.fetch(.seq_cst) == 1);
  assert(queue.bitset.items[0].fetch(.seq_cst) == 0);

  // Push twice and pop twice
  const y = queue.psh_bgn();
  const z = queue.psh_bgn();
  assert(y == 1);
  assert(z == 2);
  assert(queue.pop_bgn() == ~@as(u32, 0));
  queue.psh_end(y);
  assert(queue.pop_bgn() == y);
  assert(queue.pop_bgn() == ~@as(u32, 0));
  queue.psh_end(z);
  assert(queue.pop_bgn() == z);
  queue.pop_end(y);
  queue.pop_end(z);
}



// pub fn Channel(comptime size: u32) type {
//   return struct {
//     mutex: std.Thread.Mutex,
//     producer_sem: std.Thread.Semaphore,
//     consumer_sem: std.Thread.Semaphore,
//     buffer: [size]i32,
//     head: usize,
//     tail: usize,
//     cnt: usize,
//     closed: bool,

//     fn init() @This() {
//       return @This(){
//         .mutex = std.Thread.Mutex{},
//         .producer_sem = std.Thread.Semaphore{},
//         .consumer_sem = std.Thread.Semaphore{},
//       };
//     }
//     fn send(self: *@This(), val: i32) void {
//       self.mutex.lock();
//       defer self.mutex.unlock();

      
//     }
//   };
// }
//


// const WorkTag = enum {
//   File, Coroutine,
// };

// const Work = struct {
  
// };

const FileTask = struct {
  co: *Lua,
  yield_strs: ArrayList([]const u8), // events being wated on
  waiting_strs: ArrayList([]const u8), // Same as yield_strs, except that elements wil lbe removed when satisfied
  
};

// const Work = struct {
//   next: ?*Work,
//   co: *Lua,
//   path: [:0]const u8,
//   yield_strs: ArrayList([:0]const u8), // events being wated on
//   waiting_strs: ArrayList([:0]const u8), // Same as yield_strs, except that elements wil lbe removed when satisfied
//   thread_idx: u32,
// };

// const ThreadData = struct {
//   head: ?*Work,
//   cnd_var: std.Thread.Condition,
//   waiting: bool,
// };

fn Fifo(comptime T: type, comptime size: isize) type {
  return std.fifo.LinearFifo(T, std.fifo.LinearFifoBufferType{.static=size});
}

const ObjListener = struct {
  next: ?*ObjListener,
  trigger_sem: Thread.Semaphore,
  co: *Lua,
};

const Program = struct {
  // channel: std.Channel(u32),
  const size = 1024;
  allocator: Allocator,
  num_thrds: u32,
  dir: fs.Dir,

  // Main queue containing filepaths to process
  queue: Mpmc(size),
  queue_elems: [size][]const u8,
  producer_sem: std.Thread.Semaphore,
  // consumer_sem: std.Thread.Semaphore,

  // Queue of semaphores for waiting consumer threads
  num_waiters: std.atomic.Value(u32), // This atomic u32 is used for ensuring no threads get abandoned due to bad synchronization. If a thread is about to push semaphore, but the producer thread sees an empty semaphore-queue, then we got an underutilization-bug(and perhaps even "deadlock") because the producer thread is supposed to wake up but doesn't. Incrementing num_waiters will notify the producer thread that a thread might go into waiting state, so the producer thread will spin lock until either the producer thread found some other work to do or is done pushing to consumer_sem_queue.
  consumer_sem_queue: Mpmc(size), // TODO: Make the size of threadpool
  consumer_sem_queue_elems: [size]*Thread.Semaphore,



  obj_mutex: Thread.Mutex,
  obj_listeners: std.StringHashMap(*ObjListener),
  objs: std.StringHashMap([:0]const u8),

  // mutex: std.Thread.Mutex,
  // ThreadData: []ThreadData,
  // waiters: Fifo(Thread.Condition, size),
  // // listeners: std.AutoHashMap([:0]const u8, *Work),
  // // // TODO: Use a lockfree hashmap(except lock on resize)
  // // objs: std.AtuoHashMap([:0]const u8, [:0]const u8),
  

  
  
  close: std.atomic.Value(bool),

  pub fn init(num_thrds: u32, allocator: Allocator, dir: fs.Dir) Program {
    assert(num_thrds <= size);
    return Program {
      .allocator = allocator,
      // .channel = std.Channel(u32).init(allocator, 1024)
      .num_thrds = num_thrds,
      .dir = dir,
      .queue = Mpmc(size).init(),
      .queue_elems = undefined,
      .producer_sem = .{.permits = 1+0*size},
      // .consumer_sem = .{},
      .num_waiters = std.atomic.Value(u32).init(0),
      .consumer_sem_queue = Mpmc(size).init(),
      .consumer_sem_queue_elems = undefined,
      .obj_mutex = .{},
      .obj_listeners = std.StringHashMap(*ObjListener).init(allocator),
      .objs = std.StringHashMap([:0]const u8).init(allocator),
      .close = std.atomic.Value(bool).init(false),
    };
  }
  // pub fn push_filepath(path: [:0]const u8) void {
    
  // }
  // pub fn trigger_event(event: [:0]const u8) void {
    
  // }
  pub fn deinit(self: *Program) void {
    debug.print("PROGRAM DEINIT", .{});
    // self.channel.deinit();
    self.close.store(true, .seq_cst);
    // for (0..size) |_| {
    //   self.consumer_sem.post();
    // }
  }
};

// TODO: Abstract the producer-consumer with events system
fn thrd_function(program: *Program) !void {
  const allocator = program.allocator;

  var lua: *Lua = try Lua.init(allocator);
  defer lua.deinit();
  lua.openLibs();
  try lua.doString("print('helloooo')");
  const lua_file = "./lua_test.lua";
  _ = lua.doFile(lua_file) catch |e| {
    // const err_msg = lua.toString(-1);
    
    // const msg = lua.getGlobal("debug").getField("traceback");
    // if (msg != null) {
      std.debug.print("Lua error: {}\n", .{e});
      // std.debug.print("Lua error: {}\n", .{err_msg});
    // }
  };

  var sem: Semaphore = .{};
  var is_waiter = false;

  var notified_obj_listener = std.atomic.Value(?*ObjListener).init(null);

  const lua_top = lua.getTop();

  while(true) {
    // if (lua.getTop() != lua_top) {
      debug.print("Expected {}, got {}\n", .{lua_top, lua.getTop()});
    // }
    assert(lua.getTop() == lua_top); // Stack must not grow

    
    // debug.print("Gonna wait\n", .{});
    // program.consumer_sem.wait();
    // program.mutex.lock();
    // thread_data.waiting = true;
    // program.waiters.push(thread_data.cnd_var);
    // thread_data.cnd_var.wait(program.mutex);
    
    // debug.print("done wait\n", .{});
    var num_args: i32 = 0;

    //// Resume coroutine if obj-listener have been notified, else create a lua-thread and call coroutine.
    var co: *Lua = undefined;
    const obj_listener = notified_obj_listener.load(.seq_cst);
    if (obj_listener != null) {
      assert(!is_waiter);
      // if (is_waiter) {
      //   // const num_waiters = program.num_waiters.fetchSub(1, .seq_cst);
      //   // assert(num_waiters > 0);
      //   is_waiter = false;
      // }
      notified_obj_listener.store(null, .seq_cst);
      obj_listener.?.trigger_sem.post();
      // const key = obj_listener.key;
      // const obj = obj_listener.obj;
      co = obj_listener.?.co;
      allocator.destroy(obj_listener.?);
    } else {

      //// Try pop filepath from queue, otherwise wait and continue loop
      if (!is_waiter) { // Ensure producer thread is able to wake up this thread, by spinlocking the producer when num_waiters > 0.
        _ = program.num_waiters.fetchAdd(1, .seq_cst); // TODO: Actually move to the producer-code to reduce spinning
        is_waiter = true;
      }
      const idx: u32 = program.queue.pop_bgn();
      debug.print("{}", .{@as(i32, @bitCast(idx))});
      if (idx == ~@as(u32, 0)) {
        if (program.close.load(.seq_cst) == true) {
          break;
        }
        const idx2 = program.consumer_sem_queue.psh_bgn();
        assert(idx2 != minus_one(u32));
        program.consumer_sem_queue_elems[idx2] = &sem;
        program.consumer_sem_queue.psh_end(idx2);
        debug.print("Consumer waiting\n", .{});
        sem.wait();
        debug.print("Consumer done waiting!", .{});
        is_waiter = false;
        continue;
      }
      assert(is_waiter);
      if (is_waiter) {
        const num_waiters = program.num_waiters.fetchSub(1, .seq_cst);
        assert(num_waiters > 0);
        is_waiter = false;
      }
      debug.print("..\n", .{});

      // Grab element and end pop.
      const path = program.queue_elems[idx];
      debug.print("We got path:'{s}', the strlen is {}\n", .{path, path.len});
      debug.print("Index of null terminator is: {?}\n", .{std.mem.indexOfScalar(u8, path, 0)});
      debug.print("Index of null terminator is: {?}\n", .{std.mem.indexOfScalar(u8, "action.cdebug.h.", 0)});
      program.queue.pop_end(idx);
      debug.print("Consumer signal producer\n", .{});
      program.producer_sem.post();
      // program.mutex.unlock();

      // Open file:
      const file: fs.File = try fs.Dir.openFile(program.dir, path, .{.mode = .read_only, .lock = .exclusive});
      const file_size: u64 = try file.getEndPos();
      const src = try allocator.alloc(u8, @intCast(file_size));
      defer allocator.free(src);
      const bytes_read = try file.readAll(src);
      assert(bytes_read == file_size);
      file.close();
      


      //// Create a lua-thread(coroutine)    
      // TODO: Make process_file optional, alternatives like process_line could be added perhaps.
      // Get the coroutine and create lua-thread
      debug.print("LUA.NEWTHREAD\n", .{});
      co = lua.newThread();
      const co_reg_idx: i32 = try lua.ref(zlua.registry_index);
      _ = co_reg_idx;
      // lua_top += 1;
      _ = co.getGlobal("process_file") catch {
        debug.print("error: no variable process_file found!\n", .{});
        // std.process.exit(-1);
        continue;
      };
      if (!co.isFunction(-1)) {
        debug.print("error: no function process_file found!\n", .{});
        co.pop(1);
        // std.process.exit(-1);
        continue;
      }
      num_args = 2;
      _ = co.pushString(path); // 1st argument to function is filepath
      // lua.xMove(co, 1);
      _ = co.pushString(src); // 2nd argument is src 
    }

    // Call coroutine
    debug.print("CALL COROUTINE\n", .{});
    while(true) {
      var num_results: i32 = undefined;
      debug.print("RESUME THREAD\n", .{});
      const status = co.resumeThread(lua, num_args, &num_results) catch |err| {
        debug.print("Error: {}\n", .{err});
        debug.print("Error message: {s}\n", .{try co.toString(-1)});
        co.pop(1);
        return err;
      };
      if (status == .ok) {
        debug.print("CLOSING THREAD\n", .{});
        try co.closeThread(lua);
        // lua.replace(co_sp);
        co.pop(num_results);
        break;
        // TODO: Write output to file
      } else if (status == .yield) {
        var objs = try allocator.alloc([:0]const u8, @intCast(num_results));
        defer allocator.free(objs);
        var satisfied = true;
        program.obj_mutex.lock();
        debug.print("yielded values:\n", .{});
        for (0..@intCast(num_results)) |i| {
          const key_cstr: [:0]const u8 = try co.toString(-num_results + @as(i32, @intCast(i)));
          const key = key_cstr[0..];
          debug.print("  {s}", .{key});
          if (program.objs.get(key)) |obj| {
            objs[i] = obj;
          } else {
            satisfied = false;
            const prev_head: ?*ObjListener = program.obj_listeners.get(key);
            const new_head: *ObjListener = try allocator.create(ObjListener);
            new_head.* = .{
              .next = prev_head,
              .trigger_sem = sem,
              .co = co,
            };
            try program.obj_listeners.put(key, new_head);
          }
        }
        program.obj_mutex.unlock();
        co.pop(num_results);
        if (!satisfied) {
          break;
        }
        for (objs) |obj_str| {
          try co.loadString(obj_str);
        }
        continue;
      } else unreachable;
    }
  }
  debug.print("Closing thread function\n", .{});
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  const arena_allocator = arena.allocator();
  defer arena.deinit();
  const allocator = gpa.allocator();
  const thrd_cnt = 1;
  const thrds = try allocator.alloc(std.Thread, thrd_cnt);
  defer allocator.free(thrds);

  const cwd: fs.Dir = try fs.Dir.openDir(fs.cwd(), "./../vxl/src/", .{.access_sub_paths = true, .iterate = true});
  var program = Program.init(thrd_cnt, allocator, cwd);
  // defer program.deinit();

  for (thrds) |*thrd| {
    thrd.* = try std.Thread.spawn(.{}, thrd_function, .{@as(*Program, &program)});
  }
  defer {
    program.deinit();
    for (thrds) |thrd| {
      thrd.join();
    }
    std.process.exit(0);
  }

  // var lua = try Lua.init(allocator);
  // defer lua.deinit();
  // lua.openLibs();
  // try lua.doString("print('helloooo')");
  // const lua_file = "./lua_test.lua";
  // _ = lua.doFile(lua_file) catch |e| {
  //   // const err_msg = lua.toString(-1);
    
  //   // const msg = lua.getGlobal("debug").getField("traceback");
  //   // if (msg != null) {
  //     std.debug.print("Lua error: {}\n", .{e});
  //     // std.debug.print("Lua error: {}\n", .{err_msg});
  //   // }
  // };

  const t0 = time.nanoTimestamp();
  
  // var dir = try fs.Dir.openDir(cwd, "src");
  // var walker = try fs.Dir.walk(cwd, allocator);
  var walker = try cwd.walk(arena_allocator);
  defer walker.deinit();

  var timestamps = ArrayList(i128).init(allocator);
  defer ArrayList(i128).deinit(timestamps);
  
  // if (true) {
  while(try walker.next()) |d| {
    if (d.kind != .file) continue;
    // _ = d;
    const t = time.nanoTimestamp();
    try ArrayList(i128).append(&timestamps, t);
    
    // Push filepath to queue
    debug.print("Producer waiting...\n", .{});
    program.producer_sem.wait();
    debug.print("Producer done waiting!\n", .{});
    
    const idx = program.queue.psh_bgn();
    debug.print("Producer idx: {}\n", .{idx});
    assert(idx != ~@as(u32, 0));
    // const the_path: [] const u8 = std.mem.span(@as([*:0] const u8, d.path));
    const the_path = try allocator.dupe(u8, d.path);
    debug.print("Path: {s}\n", .{the_path});
    program.queue_elems[idx] = the_path;
    program.queue.psh_end(idx);

    // Now notify a thread
    while(program.num_waiters.load(.seq_cst) != 0) {
      const sem_queue_idx = program.consumer_sem_queue.pop_bgn();
      if (sem_queue_idx == ~@as(u32, 0)) {
        continue; // Pop failed
      }
      const num_waiters = program.num_waiters.fetchSub(1, .seq_cst);
      assert(num_waiters > 0);
      const consumer_sem = program.consumer_sem_queue_elems[sem_queue_idx];
      program.consumer_sem_queue.pop_end(sem_queue_idx);
      debug.print("Producer signal consumer\n", .{});
      consumer_sem.post();
      break;
    }
    
    //
    // program.consumer_sem.post();
    // debug.print("Path: {s}\n", .{d.path});
  }
  // }
  const t1 = time.nanoTimestamp();
  for (timestamps.items) |t| {
    // debug.print("t: {} ns\n", .{t - t0});
    _ = t;
  }
  debug.print("Time elapsed: {} ns\n", .{t1 - t0});
  debug.print("CLOOOSSSINNNGG", .{});

  // while(true) {
  //   std.debug.print("ok\n", .{});
  // // while(try walker.next()) |d| {
  //   const d = try walker.next();
  //   if (d == null) break;
  //   std.debug.print("Path: {s}\n", .{d.?.path});
  // }
  
  
}
