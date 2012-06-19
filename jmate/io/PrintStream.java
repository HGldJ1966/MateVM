package jmate.io;

public class PrintStream {
	public void println(String a) {
		// TODO: `a + "\n"' when StringBuilder is available
		printf(a);
		printf("\n");
	}

	public PrintStream printf(String format, Object... args) {
		/* temporary workaround ;-) */
		int len = args.length;
		if (len == 0) {
			this.printf_0(format);
		} else if (len == 1) {
			this.printf_1(format, args[0]);
		} else if (len == 2) {
			this.printf_2(format, args[0], args[1]);
		} else if (len == 3) {
			this.printf_3(format, args[0], args[1], args[2]);
		} else if (len == 4) {
			this.printf_4(format, args[0], args[1], args[2], args[3]);
		} else if (len == 5) {
			this.printf_5(format, args[0], args[1], args[2], args[3], args[4]);
		}
		return this;
	}

	public native void printf_0(String a);
	public native void printf_1(String a, Object b);
	public native void printf_2(String a, Object b, Object c);
	public native void printf_3(String a, Object b, Object c, Object d);
	public native void printf_4(String a, Object b, Object c, Object d, Object e);
	public native void printf_5(String a, Object b, Object c, Object d, Object e, Object f);
}
