package tests;

public class Generics1 implements Cmp<Integer> {
	public Integer a = new Integer(0x1337);
	public int cmpto(Integer o) {
		return a.intValue() - o.intValue();
	}

	public static Cmp<Integer> sb = new Generics1();
	public static int lalelu = 0;

	public static void main(String []args) {
		Generics1 foo = new Generics1();
		System.out.printf("0x%08x\n", foo.cmpto(0x666));
		System.out.printf("0x%08x\n", sb.cmpto(0x666));
	}
}

interface Cmp<T>
{
	int cmpto(T o);
}
