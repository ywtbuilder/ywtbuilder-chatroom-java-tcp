package server;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.net.*;
import java.awt.*;
import java.io.*;

import javax.swing.*;
import javax.swing.border.Border;

public class serverDemo extends JFrame{
    JButton send_button;
    JTextArea out = new JTextArea(1, 30);   // 发送框
    JTextArea in = new JTextArea(15, 30);   // 接收框
    JPanel pan = new JPanel();

    public serverDemo(){      // 创建UI
        super("Server");
        Border border = BorderFactory.createLineBorder(Color.green, 1);
        in.setBorder(border);
        out.setBorder(border);
        send_button = new JButton("公告");
        send_button.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                try {
                    String message_out = out.getText();
                    for (int i = 0; i < sockets.index_serverOut; i++) {
                        sockets.outStreams[i].write(("Server：" + message_out + "\n").getBytes());
                        sockets.outStreams[i].flush();
                    }
                    out.setText("");
                } catch (IOException f) {
                    System.out.println("Error: " + f);
                }
            }
        });

        pan.setLayout(new FlowLayout());
        pan.add(in);
        pan.add(out);
        pan.add(send_button);

        add(pan);
        setSize(350, 370);
        setVisible(true);
        setDefaultCloseOperation(JFrame.DISPOSE_ON_CLOSE);

        try{                    // 尝试连接并获取流
            ServerSocket serverInter1 = new ServerSocket(6666);
            ServerSocket serverInter2 = new ServerSocket(6667);
            ServerSocket serverInter3 = new ServerSocket(6668);

            thread v1 = new thread(serverInter1, in,out, send_button);
            v1.setName("user1");
            v1.start();

            thread v2 = new thread(serverInter2, in,out, send_button);
            v2.setName("user2");
            v2.start();

            thread v3 = new thread(serverInter3, in,out, send_button);
            v3.setName("user3");
            v3.start();
        }catch(IOException e){
            System.out.println("Error:"+e);
        }
    }

    public static void main(String[] args) {
        new serverDemo();
    }
}