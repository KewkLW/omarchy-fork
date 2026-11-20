#!/usr/bin/env python3
# TEMP herald (scratch branch only, never upstream): two XWayland windows of
# class steam_app_battlenet, "Battle.net" and "World of Warcraft". After a
# pause (while the caller focuses Battle.net) it asks the window manager to
# activate World of Warcraft with _NET_ACTIVE_WINDOW, as Wine does, then holds
# the windows for a while and exits.
import ctypes
import sys
import time
from ctypes import POINTER, Structure, Union, byref, c_char_p, c_int, c_long, c_uint, c_ulong, c_void_p

pause, hold = float(sys.argv[1]), float(sys.argv[2])
x = ctypes.cdll.LoadLibrary("libX11.so.6")
x.XOpenDisplay.restype = c_void_p
x.XOpenDisplay.argtypes = [c_char_p]
x.XDefaultRootWindow.restype = c_ulong
x.XDefaultRootWindow.argtypes = [c_void_p]
x.XCreateSimpleWindow.restype = c_ulong
x.XCreateSimpleWindow.argtypes = [c_void_p, c_ulong, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong]
x.XInternAtom.restype = c_ulong
x.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]


class XClassHint(Structure):
    _fields_ = [("res_name", c_char_p), ("res_class", c_char_p)]


class XClientMessageEvent(Structure):
    _fields_ = [("type", c_int), ("serial", c_ulong), ("send_event", c_int), ("display", c_void_p),
                ("window", c_ulong), ("message_type", c_ulong), ("format", c_int), ("l", c_long * 5)]


class XEvent(Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", c_long * 24)]


x.XSetClassHint.argtypes = [c_void_p, c_ulong, POINTER(XClassHint)]
x.XStoreName.argtypes = [c_void_p, c_ulong, c_char_p]
x.XMapWindow.argtypes = [c_void_p, c_ulong]
x.XFlush.argtypes = [c_void_p]
x.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_long, POINTER(XEvent)]

d = x.XOpenDisplay(None)
if not d:
    print("x11: no display", flush=True)
    sys.exit(1)
root = x.XDefaultRootWindow(d)
windows = {}
for title in ("Battle.net", "World of Warcraft"):
    w = x.XCreateSimpleWindow(d, root, 0, 0, 400, 300, 0, 0, 0xffffff)
    hint = XClassHint(b"steam_app_battlenet", b"steam_app_battlenet")
    x.XSetClassHint(d, w, byref(hint))
    x.XStoreName(d, w, title.encode())
    x.XMapWindow(d, w)
    windows[title] = w
x.XFlush(d)
print("x11: mapped " + ", ".join(f"{t}={w:#x}" for t, w in windows.items()), flush=True)

time.sleep(pause)
ev = XEvent()
ev.xclient.type = 33  # ClientMessage
ev.xclient.send_event = 1
ev.xclient.display = d
ev.xclient.window = windows["World of Warcraft"]
ev.xclient.message_type = x.XInternAtom(d, b"_NET_ACTIVE_WINDOW", 0)
ev.xclient.format = 32
ev.xclient.l[0] = 1  # source: an application
x.XSendEvent(d, root, 0, (1 << 20) | (1 << 19), byref(ev))
x.XFlush(d)
print(f"x11: sent _NET_ACTIVE_WINDOW for World of Warcraft at {time.time():.1f}", flush=True)
time.sleep(hold)
