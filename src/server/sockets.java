package server;
import java.io.OutputStream;

public class sockets {
    public static OutputStream[] outStreams = new OutputStream[10];
    public static int index_serverOut;
    public static String[] names = new String[10];

    public sockets(OutputStream outStream, String name) {
        names[index_serverOut] = name;
        outStreams[index_serverOut++] = outStream;
    }

    // 可选：添加方法来移除断开连接的客户端
    public static void removeClient(int index) {
        if (index >= 0 && index < index_serverOut) {
            names[index] = names[index] + "（离线）";
            outStreams[index] = null;
            // 将数组中后面的元素前移，如果需要保持连续
            for (int i = index; i < index_serverOut - 1; i++) {
                names[i] = names[i + 1];
                outStreams[i] = outStreams[i + 1];
            }
            index_serverOut--;
        }
    }
}